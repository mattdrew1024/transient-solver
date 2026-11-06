function report = inspectCircuit(modelOrFile, outputFolder, varargin)
%INSPECTCIRCUIT  Inventory, topology, and linearity screen for a Simscape circuit.
%
%   report = inspectCircuit(model)
%   report = inspectCircuit(model, outputFolder)
%   report = inspectCircuit(model, outputFolder, 'CloseModel', true)
%
%   model         Name of a model on the MATLAB path, or a full/relative path
%                 to a .slx or .mdl file.
%   outputFolder  Optional. When non-empty, the CSV files are written there
%                 (see writeInspectionReport).
%   'CloseModel'  Optional (default false). Close the model afterwards, but
%                 only if inspectCircuit was the one that loaded it.
%
%   report is a struct of tables:
%     Summary     1 row: overall classification, explanation, counts
%     Components  1 row per block: diagram position, role, linearity verdict
%     Ports       1 row per port: terminal name, NetID, electrical NodeID
%     Nets        1 row per connected net: which component terminals share it
%     Netlist     1 row per two-terminal electrical element: + node, - node, value
%     Parameters  every dialog parameter: prompt, raw expression, unit
%     Warnings    topology / configuration / extraction issues
%
%   The model is loaded if necessary, but never simulated, modified, or saved.
%
%   Error reporting: if something fails, the thrown error names the stage
%   and the block being processed, and keeps the original error as its
%   cause. Pass it to formatErrorReport(ME) to get every file, function and
%   line number in the chain, with the source text of each failing line.
%   Errors that only affect one block do not stop the inspection; they are
%   recorded in report.Warnings with the code location in the Location column.

if nargin < 2 || isempty(outputFolder)
    outputFolder = '';
end
opts = parseOptions(varargin{:});

% ---------------- state shared with the nested functions ----------------
stage      = 'starting';             % what is being done right now
stageBlock = '';                     % which block/system it is being done to
warnRows   = cell(0, 5);             % Severity, Code, ComponentID, Message, Location
ufIndex    = containers.Map('KeyType', 'double', 'ValueType', 'double');
ufParent   = zeros(1, 0);            % union-find parent array over handles

try
    % ------------------------------------------------------------------
    stage = 'loading the model';
    [model, modelFile, wasLoaded, loadNote] = loadModel(modelOrFile);
    cleaner = onCleanup(@() closeIfRequested(model, wasLoaded, opts.CloseModel)); %#ok<NASGU>
    if ~isempty(loadNote)
        addWarning('WARNING', 'MODEL_ALREADY_LOADED', '', loadNote);
    end
    if ~strcmpi(get_param(model, 'BlockDiagramType'), 'model')
        addWarning('WARNING', 'NOT_A_MODEL', '', sprintf( ...
            '"%s" is a %s, not a model; results may be incomplete.', ...
            model, get_param(model, 'BlockDiagramType')));
    end

    % ------------------------------------------------------------------
    stage = 'walking the model hierarchy';
    rootH = get_param(model, 'Handle');
    [blockH, hierFlag, systems] = collectBlocks(rootH);
    nB = numel(blockH);

    % ------------------------------------------------------------------
    stage = 'reading block properties';
    comp = repmat(emptyComponent(), 1, nB);
    for c = 1:nB
        h = blockH(c);
        comp(c).ID = sprintf('B%04d', c);
        comp(c).Handle = h;
        comp(c).IsHierarchy = hierFlag(c);
        try
            stageBlock = cleanText(getfullname(h));
            comp(c).Path = stageBlock;
            comp(c).Name = cleanText(get_param(h, 'Name'));
            comp(c).Parent = cleanText(get_param(h, 'Parent'));
            comp(c).BlockType = get_param(h, 'BlockType');
            comp(c).ReferenceBlock = cleanText(getParamOr(h, 'ReferenceBlock', ''));
            comp(c).ComponentPath = cleanText(getParamOr(h, 'ComponentPath', ''));
            comp(c).Position = double(get_param(h, 'Position'));
            comp(c).Orientation = getParamOr(h, 'Orientation', '');
        catch ME
            addWarning('ERROR', 'BLOCK_READ_FAILED', comp(c).ID, ME.message, codeLocation(ME));
        end
    end
    stageBlock = '';

    % ------------------------------------------------------------------
    stage = 'reading ports';
    portH = zeros(1, 0);
    portComp = zeros(1, 0);
    portGroup = cell(1, 0);
    portIdx = zeros(1, 0);
    portXY = zeros(0, 2);
    portLine = zeros(1, 0);
    for c = 1:nB
        stageBlock = comp(c).Path;
        try
            ph = get_param(comp(c).Handle, 'PortHandles');
            groups = fieldnames(ph);
            for g = 1:numel(groups)
                hs = ph.(groups{g});
                for k = 1:numel(hs)
                    % read everything first, then append together, so the
                    % parallel arrays can never get out of step
                    xy = double(get_param(hs(k), 'Position'));
                    ln = double(get_param(hs(k), 'Line'));
                    portH(end + 1) = hs(k);                %#ok<AGROW>
                    portComp(end + 1) = c;                 %#ok<AGROW>
                    portGroup{end + 1} = groups{g};        %#ok<AGROW>
                    portIdx(end + 1) = k;                  %#ok<AGROW>
                    portXY(end + 1, :) = xy(1:2);          %#ok<AGROW>
                    portLine(end + 1) = ln(1);             %#ok<AGROW>
                end
            end
        catch ME
            addWarning('ERROR', 'PORT_READ_FAILED', comp(c).ID, ME.message, codeLocation(ME));
        end
    end
    stageBlock = '';
    nP = numel(portH);
    isPhysPort = ismember(portGroup, {'LConn', 'RConn'});

    % ------------------------------------------------------------------
    stage = 'classifying components';
    paramRows = cell(0, 4);          % Name, Prompt, Value, Unit
    paramComp = zeros(0, 1);         % owning component index for each row
    for c = 1:nB
        stageBlock = comp(c).Path;
        try
            if comp(c).IsHierarchy
                comp(c).Role = 'HIERARCHY';
                comp(c).Assessment = 'HIERARCHY';
                comp(c).Reason = ['User subsystem. Its contents are listed as separate ' ...
                    'components, and its connection ports are merged with the ' ...
                    'Connection Port blocks inside it.'];
                continue
            end

            rule = lookupRule(comp(c).BlockType, comp(c).ReferenceBlock, comp(c).ComponentPath);
            params = getDialogParams(comp(c).Handle);
            nPhys = sum(portComp == c & isPhysPort);
            [assessment, reason] = applyChecks(rule, params, nPhys, comp(c).ComponentPath);

            comp(c).Rule = rule;
            comp(c).Params = params;
            comp(c).Role = rule.Role;
            comp(c).Domain = rule.Domain;
            comp(c).Assessment = assessment;
            comp(c).Reason = reason;

            if ~isempty(params)
                paramRows = [paramRows; params];                          %#ok<AGROW>
                paramComp = [paramComp; repmat(c, size(params, 1), 1)];   %#ok<AGROW>
            end

            if strcmp(assessment, 'UNKNOWN')
                addWarning('WARNING', 'UNREVIEWED_BLOCK', comp(c).ID, reason);
            end
            if strcmp(comp(c).BlockType, 'ModelReference')
                addWarning('WARNING', 'MODEL_REFERENCE_NOT_INSPECTED', comp(c).ID, ...
                    'Referenced models are not opened; their contents are missing from every table.');
            end
        catch ME
            comp(c).Assessment = 'UNKNOWN';
            comp(c).Reason = ['Classification failed: ' ME.message];
            addWarning('ERROR', 'CLASSIFY_FAILED', comp(c).ID, ME.message, codeLocation(ME));
        end
    end
    stageBlock = '';

    % designators (R1, C1, V1, GND1 ...) in component order
    counters = containers.Map('KeyType', 'char', 'ValueType', 'double');
    for c = 1:nB
        pfx = comp(c).Rule.Prefix;
        if comp(c).IsHierarchy || isempty(pfx)
            continue
        end
        if isKey(counters, pfx)
            counters(pfx) = counters(pfx) + 1;
        else
            counters(pfx) = 1;
        end
        comp(c).Designator = sprintf('%s%d', pfx, counters(pfx));
    end

    % ------------------------------------------------------------------
    % Topology. Every port handle and every line-segment handle is a node in
    % a union-find structure. Anything that is electrically the same wire
    % ends up with the same root: segments of one branched line, the ports
    % at its ends, a subsystem port and the Connection Port block behind it,
    % and Connection Label blocks that share a label.
    stage = 'tracing wires';
    for k = 1:nP
        ufAdd(portH(k));
        if portLine(k) ~= -1
            ufUnion(portH(k), portLine(k));
        end
    end
    for s = 1:numel(systems)
        stageBlock = safeFullName(systems(s));
        try
            lineHs = find_system(systems(s), 'SearchDepth', 1, 'FindAll', 'on', ...
                'LookUnderMasks', 'all', 'FollowLinks', 'on', 'Type', 'line');
            for L = lineHs(:).'
                traceLine(L);
            end
        catch ME
            addWarning('ERROR', 'LINE_TRACE_FAILED', '', ...
                sprintf('%s: %s', stageBlock, ME.message), codeLocation(ME));
        end
    end
    stageBlock = '';

    stage = 'mapping subsystem connection ports';
    for s = 2:numel(systems)          % systems(1) is the model root
        try
            mapConnectionPorts(systems(s));
        catch ME
            addWarning('ERROR', 'PORT_MAP_FAILED', '', ...
                sprintf('%s: %s', stageBlock, ME.message), codeLocation(ME));
        end
    end
    stageBlock = '';

    stage = 'merging Connection Label blocks';
    mergeConnectionLabels();
    stageBlock = '';

    % ------------------------------------------------------------------
    stage = 'numbering nets and electrical nodes';
    roles = {comp.Role};
    isRealComp = ~ismember(roles, {'HIERARCHY', 'CONNECTOR'});
    rootOf = zeros(1, nP);
    for k = 1:nP
        rootOf(k) = ufFind(ufAdd(portH(k)));
    end
    [~, ~, grp] = unique(rootOf, 'stable');
    grp = grp(:).';
    nGroups = max([grp, 0]);

    portNet = repmat({''}, 1, nP);
    portNode = repmat({''}, 1, nP);
    netRows = cell(0, 6);           % NetID, Kind, NodeID, IsGround, ComponentPortCount, Members
    netMembersComp = cell(1, 0);    % component indices on each real net
    netIsPhys = false(1, 0);
    netCounter = 0;
    nodeCounter = 0;
    for gIdx = 1:nGroups
        members = find(grp == gIdx);
        compPorts = members(isRealComp(portComp(members)));
        hasWire = numel(members) > 1 || any(portLine(members) ~= -1);
        if isempty(compPorts) || ~hasWire
            continue                % unconnected port (or only hierarchy plumbing)
        end
        netCounter = netCounter + 1;
        netID = sprintf('N%03d', netCounter);
        phys = any(isPhysPort(members));

        onNet = unique(portComp(compPorts));
        isGround = phys && any(arrayfun(@(c) strcmp(comp(c).Role, 'REFERENCE') && ...
            strcmp(comp(c).Domain, 'electrical'), onNet));
        if ~phys
            nodeID = '';
        elseif isGround
            nodeID = '0';
        else
            nodeCounter = nodeCounter + 1;
            nodeID = sprintf('n%d', nodeCounter);
        end
        [portNet{members}] = deal(netID);
        [portNode{members}] = deal(nodeID);

        labels = arrayfun(@(k) portLabel(comp(portComp(k)), portGroup{k}, portIdx(k)), ...
            compPorts, 'UniformOutput', false);
        if phys
            kind = 'Physical';
        else
            kind = 'Signal';
        end
        netRows(end + 1, :) = {netID, kind, nodeID, isGround, numel(compPorts), ...
            strjoin(labels, '; ')};                                        %#ok<AGROW>
        netMembersComp{end + 1} = onNet;                                   %#ok<AGROW>
        netIsPhys(end + 1) = phys;                                         %#ok<AGROW>

        if numel(compPorts) == 1
            addWarning('WARNING', 'DANGLING_WIRE', comp(portComp(compPorts)).ID, sprintf( ...
                '%s is wired, but nothing else is on the other end of that wire (net %s).', ...
                labels{1}, netID));
        end
    end

    nRefs = sum(arrayfun(@(c) strcmp(c.Role, 'REFERENCE') && strcmp(c.Domain, 'electrical'), comp));
    if nRefs > 1
        addWarning('INFO', 'MULTIPLE_REFERENCES', '', sprintf( ...
            ['%d Electrical Reference blocks found. Every Electrical Reference is the same ' ...
            '0 V node, so all of them are reported as node 0.'], nRefs));
    end

    % ------------------------------------------------------------------
    stage = 'finding physical networks';
    label = 1:nB;
    for n = find(netIsPhys)
        cs = netMembersComp{n};
        if numel(cs) > 1
            old = unique(label(cs));
            label(ismember(label, old)) = min(old);
        end
    end
    hasConnectedPhys = false(1, nB);
    for k = find(isPhysPort & ~cellfun(@isempty, portNet))
        hasConnectedPhys(portComp(k)) = true;
    end
    hasConnectedPhys = hasConnectedPhys & isRealComp;
    netLabels = unique(label(hasConnectedPhys), 'stable');
    for w = 1:numel(netLabels)
        inNet = find(hasConnectedPhys & label == netLabels(w));
        nwID = sprintf('NW%d', w);
        [comp(inNet).Network] = deal(nwID);
        r = {comp(inNet).Role};
        d = {comp(inNet).Domain};
        if ~any(strcmp(r, 'SOLVER'))
            addWarning('ERROR', 'NO_SOLVER_CONFIGURATION', '', sprintf( ...
                ['Physical network %s (%d blocks) has no Solver Configuration block. ' ...
                'Simscape requires exactly one per physical network; the model will not simulate.'], ...
                nwID, numel(inNet)));
        end
        if any(strcmp(d, 'electrical')) && ~any(strcmp(r, 'REFERENCE') & strcmp(d, 'electrical'))
            addWarning('ERROR', 'NO_ELECTRICAL_REFERENCE', '', sprintf( ...
                'Physical network %s has electrical elements but no Electrical Reference (ground).', nwID));
        end
    end

    % unconnected ports on real components
    for k = find(cellfun(@isempty, portNet))
        c = portComp(k);
        if isRealComp(c) && ~strcmp(comp(c).Role, 'SIGNAL')
            addWarning('INFO', 'UNCONNECTED_PORT', comp(c).ID, sprintf( ...
                '%s is not connected to anything.', portLabel(comp(c), portGroup{k}, portIdx(k))));
        end
    end

    % ------------------------------------------------------------------
    stage = 'building the netlist';
    netlistRows = cell(0, 8);
    for c = 1:nB
        rule = comp(c).Rule;
        if ~isRealComp(c) || ~strcmp(rule.Domain, 'electrical') || size(rule.Terminals, 1) ~= 2 ...
                || ~all(ismember(rule.Terminals(:, 2), {'+', '-'}))
            continue
        end
        stageBlock = comp(c).Path;
        nodes = {'?', '?'};
        for t = 1:2
            key = rule.Terminals{t, 1};
            k = find(portComp == c & strcmp(strcat(portGroup, arrayfun(@num2str, portIdx, ...
                'UniformOutput', false)), key), 1);
            if ~isempty(k) && ~isempty(portNode{k})
                nodes{t} = portNode{k};
            else
                addWarning('WARNING', 'UNCONNECTED_TERMINAL', comp(c).ID, sprintf( ...
                    'Terminal %s (%s) of %s has no electrical node; shown as "?" in the netlist.', ...
                    rule.Terminals{t, 2}, key, comp(c).Name));
            end
        end
        if strcmp(rule.Terminals{1, 2}, '+')
            pos = nodes{1}; neg = nodes{2};
        else
            pos = nodes{2}; neg = nodes{1};
        end
        netlistRows(end + 1, :) = {comp(c).Designator, comp(c).ID, comp(c).Name, ...
            comp(c).Role, comp(c).Assessment, pos, neg, valueSummary(rule, comp(c).Params)}; %#ok<AGROW>
    end
    stageBlock = '';

    % ------------------------------------------------------------------
    stage = 'checking for faults';
    try
        faults = Simulink.fault.findFaults(model);
        if ~isempty(faults)
            addWarning('WARNING', 'FAULTS_DEFINED', '', sprintf( ...
                ['%d fault(s) are defined in this model. An active fault switches an element''s ' ...
                'behavior during simulation, which this static screen does not model.'], numel(faults)));
        end
    catch
        % Fault API not available in this release/installation: nothing to check.
    end

    % ------------------------------------------------------------------
    stage = 'deciding the overall classification';
    [classification, explanation] = overallClassification(comp, isRealComp);
    if strcmp(classification, 'LINEAR_CANDIDATE') && any(strcmp(warnRows(:, 2), 'FAULTS_DEFINED'))
        explanation = [explanation ' Faults are defined in the model; see warnings.'];
    end
    if strcmp(classification, 'LINEAR_CANDIDATE')
        sensors = any(strcmp(roles, 'SENSOR'));
        driven = any(arrayfun(@(c) strcmp(c.Rule.Check, 'signal_driven'), comp));
        if sensors && driven
            classification = 'UNKNOWN';
            explanation = ['Every physical element is linear, but the model has both sensors and ' ...
                'signal-driven sources. If a Simulink signal path feeds a measurement back into a ' ...
                'source, that path decides linearity, and Simulink blocks are not analyzed here.'];
            addWarning('WARNING', 'FEEDBACK_NOT_ANALYZED', '', explanation);
        end
    end

    % ------------------------------------------------------------------
    stage = 'assembling the report tables';
    report = struct();
    report.Components = componentTable(comp);
    report.Ports = portTable();
    report.Nets = makeTable(netRows, ...
        {'NetID', 'Kind', 'NodeID', 'IsGround', 'ComponentPortCount', 'Members'});
    report.Netlist = makeTable(netlistRows, ...
        {'Designator', 'ComponentID', 'Name', 'Role', 'Assessment', ...
        'PositiveNode', 'NegativeNode', 'Value'});
    report.Parameters = parameterTable();
    report.Warnings = makeTable(warnRows, ...
        {'Severity', 'Code', 'ComponentID', 'Message', 'Location'});
    report.Summary = cell2table({model, modelFile, classification, explanation, ...
        nB, sum(isRealComp & ~strcmp(roles, 'SIGNAL')), nP, size(netRows, 1), ...
        nodeCounter + any(cell2mat([netRows(:, 4); {false}])), numel(netLabels), ...
        size(warnRows, 1), char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
        version('-release')}, 'VariableNames', ...
        {'Model', 'File', 'Classification', 'Explanation', 'BlockCount', ...
        'CircuitBlockCount', 'PortCount', 'NetCount', 'ElectricalNodeCount', ...
        'NetworkCount', 'WarningCount', 'InspectedAt', 'MATLABRelease'});

    if ~isempty(outputFolder)
        stage = 'writing CSV files';
        writeInspectionReport(report, outputFolder);
    end

catch ME
    where = stage;
    if ~isempty(stageBlock)
        where = sprintf('%s (block: %s)', stage, stageBlock);
    end
    wrapped = MException('inspectCircuit:failed', 'inspectCircuit failed while %s: %s', ...
        where, ME.message);
    wrapped = addCause(wrapped, ME);
    throw(wrapped);
end

% =====================================================================
% Nested functions (share the state variables declared at the top)
% =====================================================================

    function addWarning(severity, code, compID, msg, location)
        if nargin < 5
            location = '';
        end
        warnRows(end + 1, :) = {severity, code, compID, cleanText(msg), location};
    end

    function i = ufAdd(h)
        if isKey(ufIndex, h)
            i = ufIndex(h);
        else
            i = numel(ufParent) + 1;
            ufParent(i) = i;
            ufIndex(h) = i;
        end
    end

    function r = ufFind(i)
        r = i;
        while ufParent(r) ~= r
            r = ufParent(r);
        end
        while ufParent(i) ~= r          % path compression
            nxt = ufParent(i);
            ufParent(i) = r;
            i = nxt;
        end
    end

    function ufUnion(a, b)
        if a == -1 || b == -1
            return
        end
        ra = ufFind(ufAdd(a));
        rb = ufFind(ufAdd(b));
        if ra ~= rb
            ufParent(max(ra, rb)) = min(ra, rb);
        end
    end

    function traceLine(L)
        % One line segment: join it with its end ports and with its
        % parent/child segments (branches of the same wire).
        ufAdd(L);
        src = double(get_param(L, 'SrcPortHandle'));
        dst = double(get_param(L, 'DstPortHandle'));
        kids = getParamOr(L, 'LineChildren', []);
        par = getParamOr(L, 'LineParent', -1);
        others = [src(:); dst(:); double(kids(:)); double(par(:))];
        for o = others.'
            if o ~= -1
                ufUnion(L, o);
            end
        end
    end

    function mapConnectionPorts(sysH)
        % A subsystem's k-th LConn (RConn) port is the k-th left-side
        % (right-side) Connection Port block inside it, ordered by its
        % Port number.
        stageBlock = safeFullName(sysH);
        ext = get_param(sysH, 'PortHandles');
        kids = childBlocks(sysH);
        if isempty(kids)
            return
        end
        types = arrayfun(@(k) get_param(k, 'BlockType'), kids, 'UniformOutput', false);
        pmio = kids(strcmp(types, 'PMIOPort'));
        side = arrayfun(@(k) char(getParamOr(k, 'Side', 'Left')), pmio, 'UniformOutput', false);
        num = arrayfun(@(k) str2double(getParamOr(k, 'Port', 'NaN')), pmio);
        sides = {'Left', 'LConn'; 'Right', 'RConn'};
        for r = 1:2
            sel = find(strcmpi(side, sides{r, 1}));
            [~, order] = sort(num(sel));
            sel = sel(order);
            outer = ext.(sides{r, 2});
            if numel(outer) ~= numel(sel)
                addWarning('WARNING', 'PORT_MAP_MISMATCH', '', sprintf( ...
                    '%s: %d %s ports outside but %d %s-side Connection Port blocks inside.', ...
                    stageBlock, numel(outer), sides{r, 2}, numel(sel), sides{r, 1}));
            end
            for k = 1:min(numel(outer), numel(sel))
                for ip = physicalPorts(pmio(sel(k)))
                    ufUnion(outer(k), ip);
                end
            end
        end
    end

    function mergeConnectionLabels()
        % Connection Label blocks with the same label in the same diagram
        % are connected without a visible wire.
        first = containers.Map('KeyType', 'char', 'ValueType', 'double');
        for c2 = 1:nB
            if ~strcmp(comp(c2).Rule.Leaf, 'Connection Label')
                continue
            end
            stageBlock = comp(c2).Path;
            lbl = firstParam(comp(c2).Handle, {'Label', 'label', 'ConnectionLabel'});
            p = physicalPorts(comp(c2).Handle);
            if isempty(lbl) || isempty(p)
                addWarning('WARNING', 'LABEL_UNREAD', comp(c2).ID, ...
                    'Could not read this Connection Label''s label; it was not merged with matching labels.');
                continue
            end
            key = [comp(c2).Parent '|' lbl];
            if isKey(first, key)
                ufUnion(first(key), p(1));
            else
                first(key) = p(1);
            end
        end
    end

    function t = portTable()
        rows = cell(nP, 13);
        for k = 1:nP
            c = portComp(k);
            [term, termSrc] = terminalName(comp(c).Rule, portGroup{k}, portIdx(k));
            rows(k, :) = {sprintf('P%05d', k), comp(c).ID, comp(c).Designator, comp(c).Path, ...
                portGroup{k}, portIdx(k), term, termSrc, portXY(k, 1), portXY(k, 2), ...
                ~isempty(portNet{k}), portNet{k}, portNode{k}};
        end
        t = makeTable(rows, {'PortID', 'ComponentID', 'Designator', 'BlockPath', 'PortGroup', ...
            'PortIndex', 'Terminal', 'TerminalSource', 'X', 'Y', 'Connected', 'NetID', 'NodeID'});
    end

    function t = parameterTable()
        rows = cell(size(paramRows, 1), 6);
        for k = 1:size(paramRows, 1)
            c = paramComp(k);
            rows(k, :) = [{comp(c).ID, comp(c).Designator}, paramRows(k, :)];
        end
        t = makeTable(rows, {'ComponentID', 'Designator', 'Parameter', 'Prompt', 'Value', 'Unit'});
    end

end

% =====================================================================
% Local functions
% =====================================================================

function opts = parseOptions(varargin)
p = inputParser;
p.FunctionName = 'inspectCircuit';
addParameter(p, 'CloseModel', false, @(x) islogical(x) || isnumeric(x));
parse(p, varargin{:});
opts = p.Results;
opts.CloseModel = logical(opts.CloseModel);
end

function [model, modelFile, wasLoaded, note] = loadModel(modelOrFile)
note = '';
modelOrFile = char(modelOrFile);
if isempty(modelOrFile)
    error('inspectCircuit:noModel', 'No model was specified.');
end
[folder, model, ext] = fileparts(modelOrFile);
if ~isempty(ext) && ~any(strcmpi(ext, {'.slx', '.mdl'}))
    error('inspectCircuit:badExtension', 'Expected a .slx or .mdl file, got "%s".', ext);
end
if ~isempty(folder) && ~isfile(modelOrFile)
    error('inspectCircuit:fileNotFound', 'Model file not found: %s', modelOrFile);
end
wasLoaded = bdIsLoaded(model);
if wasLoaded
    loaded = get_param(model, 'FileName');
    if ~isempty(folder) && ~strcmpi(normPath(loaded), normPath(modelOrFile))
        note = sprintf(['A model named "%s" was already loaded from %s. That copy was ' ...
            'inspected, which may not be the file you selected. Run close_system(''%s'') ' ...
            'to inspect the selected file instead.'], model, loaded, model);
    end
elseif ~isempty(folder)
    load_system(modelOrFile);
else
    load_system(model);
end
modelFile = get_param(model, 'FileName');
end

function p = normPath(p)
% Absolute path with forward slashes, for comparing two file names.
p = strrep(char(p), '\', '/');
if ~(startsWith(p, '/') || ~isempty(regexp(p, '^[A-Za-z]:/', 'once')))
    p = [strrep(pwd, '\', '/') '/' p];
end
p = regexprep(p, '/\./', '/');
end

function closeIfRequested(model, wasLoaded, closeFlag)
if closeFlag && ~wasLoaded && bdIsLoaded(model)
    close_system(model, 0);
end
end

function [blockH, hierFlag, systems] = collectBlocks(rootH)
% Breadth-first walk. User subsystems are descended into; library
% components (including masked Simscape Electrical subsystems) are leaves.
blockH = zeros(1, 0);
hierFlag = false(1, 0);
systems = rootH;
queue = rootH;
head = 1;
while head <= numel(queue)
    sys = queue(head);
    head = head + 1;
    kids = childBlocks(sys);
    for h = kids
        descend = isUserSubsystem(h);
        blockH(end + 1) = h;            %#ok<AGROW>
        hierFlag(end + 1) = descend;    %#ok<AGROW>
        if descend
            systems(end + 1) = h;       %#ok<AGROW>
            queue(end + 1) = h;         %#ok<AGROW>
        end
    end
end
end

function h = childBlocks(sys)
searchOpts = {'SearchDepth', 1, 'LookUnderMasks', 'all', 'FollowLinks', 'on'};
try
    h = find_system(sys, 'MatchFilter', @Simulink.match.activeVariants, searchOpts{:}, ...
        'Type', 'block');
catch
    h = find_system(sys, searchOpts{:}, 'Type', 'block');
end
h = double(h(:).');
h(h == sys) = [];
end

function tf = isUserSubsystem(h)
tf = false;
if ~strcmp(get_param(h, 'BlockType'), 'SubSystem')
    return
end
ref = getParamOr(h, 'ReferenceBlock', '');
tf = isempty(ref) || isempty(libraryFamily(strtok(ref, '/')));
end

function fam = libraryFamily(libRoot)
% '' means "not a Simscape library".
switch libRoot
    case 'fl_lib'
        fam = 'fl';
    case 'ee_lib'
        fam = 'ee';
    case 'nesl_utility'
        fam = 'util';
    otherwise
        if any(startsWith(libRoot, {'fl_', 'ee_', 'nesl_', 'ssc_', 'sdl_', 'sh_', 'sm_', 'elec_'}))
            fam = 'other';
        else
            fam = '';
        end
end
end

function c = emptyComponent()
c = struct();
c.ID = '';
c.Designator = '';
c.Handle = -1;
c.IsHierarchy = false;
c.Path = '';
c.Name = '';
c.Parent = '';
c.BlockType = '';
c.ReferenceBlock = '';
c.ComponentPath = '';
c.Position = [NaN NaN NaN NaN];
c.Orientation = '';
c.Rule = defaultRule();
c.Params = cell(0, 4);
c.Role = 'UNKNOWN';
c.Domain = '';
c.Assessment = 'UNKNOWN';
c.Reason = '';
c.Network = '';
end

function r = defaultRule()
r = struct();
r.Family = '';
r.Leaf = '';
r.Role = 'UNKNOWN';
r.Domain = '';
r.Assessment = 'UNKNOWN';
r.Prefix = 'X';
r.ValuePrompts = {};
r.Check = '';
r.Terminals = cell(0, 2);
r.Reason = 'No reviewed rule for this block.';
end

function R = ruleTable()
two = {'LConn1', '+'; 'RConn1', '-'};
none = cell(0, 2);
gnd = {'LConn1', 'ground'};
lin = 'LINEAR';
nl = 'NONLINEAR';
el = 'electrical';
% Family, Leaf, Role, Domain, Assessment, Prefix, ValuePrompts, Check, Terminals, Reason
defs = {
    'fl', 'Resistor', 'PASSIVE', el, lin, 'R', {'Resistance'}, '', two, 'Ideal resistor: v = R*i.'
    'fl', 'Capacitor', 'PASSIVE', el, lin, 'C', {'Capacitance'}, '', two, 'Ideal capacitor: i = C*dv/dt (its series R and parallel G are linear too).'
    'fl', 'Inductor', 'PASSIVE', el, lin, 'L', {'Inductance'}, '', two, 'Ideal inductor: v = L*di/dt.'
    'fl', 'Mutual Inductor', 'PASSIVE', el, lin, 'K', {}, '', none, 'Linear coupled inductors.'
    'fl', 'Ideal Transformer', 'PASSIVE', el, lin, 'T', {}, '', none, 'Ideal transformer: fixed linear voltage and current ratios.'
    'fl', 'Gyrator', 'PASSIVE', el, lin, 'G', {}, '', none, 'Ideal gyrator: linear two-port.'
    'fl', 'Op-Amp', 'ACTIVE', el, lin, 'U', {}, '', none, 'Ideal op-amp constraint (v+ = v-, no input current) is linear.'
    'fl', 'Diode', 'PASSIVE', el, nl, 'D', {}, '', two, 'Diode current depends nonlinearly (piecewise or exponentially) on its voltage.'
    'fl', 'Switch', 'PASSIVE', el, nl, 'S', {}, '', none, 'Signal-controlled switch: its resistance changes with a control signal.'
    'fl', 'Variable Resistor', 'PASSIVE', el, nl, 'R', {}, '', none, 'R comes from a signal: v = R(t)*i is time-varying, not linear time-invariant.'
    'fl', 'Variable Capacitor', 'PASSIVE', el, nl, 'C', {}, '', none, 'C comes from a signal: time-varying, not linear time-invariant.'
    'fl', 'Variable Inductor', 'PASSIVE', el, nl, 'L', {}, '', none, 'L comes from a signal: time-varying, not linear time-invariant.'
    'fl', 'Memristor', 'PASSIVE', el, nl, 'M', {}, '', two, 'Memristor resistance depends on charge history.'
    'any', 'Electrical Reference', 'REFERENCE', el, 'REFERENCE', 'GND', {}, '', gnd, 'Electrical ground. Every Electrical Reference is the same node 0.'
    'fl', 'DC Voltage Source', 'SOURCE', el, 'SOURCE', 'V', {'Constant voltage'}, '', two, 'Independent source (external forcing).'
    'fl', 'AC Voltage Source', 'SOURCE', el, 'SOURCE', 'V', {'Peak amplitude', 'Phase shift', 'Frequency'}, '', two, 'Independent source (external forcing).'
    'fl', 'DC Current Source', 'SOURCE', el, 'SOURCE', 'I', {'Constant current'}, '', two, 'Independent source (external forcing).'
    'fl', 'AC Current Source', 'SOURCE', el, 'SOURCE', 'I', {'Peak amplitude', 'Phase shift', 'Frequency'}, '', two, 'Independent source (external forcing).'
    'fl', 'Controlled Voltage Source', 'SOURCE', el, 'SOURCE', 'V', {}, 'signal_driven', none, 'Source driven by a physical signal; linear as long as that signal does not depend on the circuit.'
    'fl', 'Controlled Current Source', 'SOURCE', el, 'SOURCE', 'I', {}, 'signal_driven', none, 'Source driven by a physical signal; linear as long as that signal does not depend on the circuit.'
    'fl', 'Voltage-Controlled Voltage Source', 'DEPENDENT_SOURCE', el, lin, 'E', {}, '', none, 'Linear dependent source.'
    'fl', 'Voltage-Controlled Current Source', 'DEPENDENT_SOURCE', el, lin, 'G', {}, '', none, 'Linear dependent source.'
    'fl', 'Current-Controlled Voltage Source', 'DEPENDENT_SOURCE', el, lin, 'H', {}, '', none, 'Linear dependent source.'
    'fl', 'Current-Controlled Current Source', 'DEPENDENT_SOURCE', el, lin, 'F', {}, '', none, 'Linear dependent source.'
    'any', 'Voltage Sensor', 'SENSOR', el, 'SENSOR', 'VM', {}, '', none, 'Ideal voltage sensor: draws no current.'
    'any', 'Current Sensor', 'SENSOR', el, 'SENSOR', 'AM', {}, '', none, 'Ideal current sensor: zero voltage drop.'
    'util', 'Solver Configuration', 'SOLVER', '', 'SOLVER', 'SC', {}, '', none, 'Simscape solver settings (one is required per physical network).'
    'util', 'Simulink-PS Converter', 'CONVERTER', 'signal', 'CONVERTER', 'CV', {}, '', none, 'Converts a Simulink signal into a physical signal.'
    'util', 'PS-Simulink Converter', 'CONVERTER', 'signal', 'CONVERTER', 'CV', {}, '', none, 'Converts a physical signal into a Simulink signal.'
    'util', 'Connection Port', 'CONNECTOR', '', 'CONNECTOR', '', {}, '', none, 'Subsystem connection port (wiring only).'
    'util', 'Connection Label', 'CONNECTOR', '', 'CONNECTOR', '', {}, '', none, 'Connection label (joins nets with the same label; wiring only).'
    'ee', 'Resistor', 'PASSIVE', el, lin, 'R', {'Resistance'}, 'ee_passive', two, 'Simscape Electrical resistor, linear configuration: v = R*i.'
    'ee', 'Capacitor', 'PASSIVE', el, lin, 'C', {'Capacitance'}, 'ee_capacitor', two, 'Simscape Electrical capacitor.'
    'ee', 'Inductor', 'PASSIVE', el, lin, 'L', {'Inductance'}, 'ee_passive', two, 'Simscape Electrical inductor, linear configuration: v = L*di/dt (plus linear series R and parallel G).'
    'ee', 'Voltage Source', 'SOURCE', el, 'SOURCE', 'V', {'DC voltage', 'AC voltage peak amplitude', 'AC voltage frequency'}, 'ee_source', two, 'Independent DC/AC source (external forcing).'
    'ee', 'Current Source', 'SOURCE', el, 'SOURCE', 'I', {'DC current', 'AC current peak amplitude', 'AC current frequency'}, 'ee_source', two, 'Independent DC/AC source (external forcing).'
    'ee', 'Diode', 'PASSIVE', el, nl, 'D', {}, '', two, 'Diode current depends nonlinearly on its voltage.'
    'ee', 'Nonlinear Inductor', 'PASSIVE', el, nl, 'L', {}, '', two, 'Flux-current relationship is nonlinear (saturation).'
    };
R = repmat(defaultRule(), 1, size(defs, 1));
for k = 1:size(defs, 1)
    R(k).Family = defs{k, 1};
    R(k).Leaf = defs{k, 2};
    R(k).Role = defs{k, 3};
    R(k).Domain = defs{k, 4};
    R(k).Assessment = defs{k, 5};
    R(k).Prefix = defs{k, 6};
    R(k).ValuePrompts = defs{k, 7};
    R(k).Check = defs{k, 8};
    R(k).Terminals = defs{k, 9};
    R(k).Reason = defs{k, 10};
end
end

function rule = lookupRule(blockType, ref, compPath)
% Rules are matched on the library the block came from (ReferenceBlock),
% never on the block's display name, so renaming a block does not change
% its classification.
rule = defaultRule();
libRoot = '';
leaf = '';
if ~isempty(ref)
    parts = strsplit(ref, '/');
    libRoot = parts{1};
    leaf = strtrim(parts{end});
end
fam = libraryFamily(libRoot);

if strcmp(blockType, 'PMIOPort')
    rule.Role = 'CONNECTOR';
    rule.Assessment = 'CONNECTOR';
    rule.Prefix = '';
    rule.Leaf = 'Connection Port';
    rule.Reason = 'Subsystem connection port (wiring only).';
    return
end
if strcmp(blockType, 'ModelReference')
    rule.Reason = 'Referenced model: its contents are not inspected.';
    return
end

R = ruleTable();
if ~isempty(fam)
    for k = 1:numel(R)
        if strcmpi(R(k).Leaf, leaf) && (strcmp(R(k).Family, fam) || strcmp(R(k).Family, 'any'))
            rule = R(k);
            return
        end
    end
    % Simscape library block without a reviewed rule
    rule.Leaf = leaf;
    if any(strcmp(fam, {'fl', 'ee', 'other'}))
        rule.Domain = 'electrical';
    end
    keywords = {'diode', 'transistor', 'mosfet', 'igbt', 'thyristor', 'gto', 'switch', ...
        'nonlinear', 'saturat', 'varistor', 'fuse', 'relay', 'zener', 'memristor', ...
        'hysteresis', 'lamp', 'triac', 'jfet', 'bjt'};
    hit = keywords(cellfun(@(w) contains(lower(leaf), w), keywords));
    if ~isempty(hit)
        rule.Role = 'PASSIVE';
        rule.Assessment = 'NONLINEAR';
        rule.Reason = sprintf(['No reviewed rule; the library block name "%s" contains "%s", ' ...
            'which indicates a nonlinear device. Please confirm.'], leaf, hit{1});
    else
        rule.Reason = sprintf(['Simscape library block "%s" has no reviewed rule yet. ' ...
            'Add one to ruleTable() in inspectCircuit.m after checking its equations.'], ref);
    end
    return
end

if strcmp(blockType, 'SimscapeBlock')
    rule.Domain = 'electrical';
    rule.Reason = sprintf(['Custom Simscape component (%s). Its equations decide linearity; ' ...
        'review the .ssc source.'], compPath);
    return
end

rule.Role = 'SIGNAL';
rule.Assessment = 'SIGNAL';
rule.Prefix = '';
rule.Domain = 'signal';
rule.Reason = 'Simulink signal block: not part of the physical circuit and not analyzed.';
end

function [assessment, reason] = applyChecks(rule, params, nPhys, componentPath)
% Simscape Electrical blocks can be linear or nonlinear depending on their
% settings, so their dialog parameters are checked, not just their identity.
assessment = rule.Assessment;
reason = rule.Reason;
notes = {};
switch rule.Check
    case {'ee_passive', 'ee_capacitor'}
        % Thermal port: either a separate "_thermal" component variant
        % (Resistor, Inductor: ComponentPath ee.passive.resistor_thermal) or
        % a boolean parameter (Capacitor: thermalEnable), or the old
        % "Modeling option" prompt. A third physical port is the fallback.
        modeling = lower(promptValue(params, 'Modeling option'));
        thermalOpt = lower(paramValue(params, {'thermalEnable', 'thermal_enable'}, ...
            {'Model thermal port', 'Thermal port'}));
        isThermalVariant = endsWith(lower(char(componentPath)), '_thermal');
        if nPhys > 2 || isThermalVariant || any(strcmp(thermalOpt, {'on', 'true', '1', 'yes'})) ...
                || contains(modeling, 'thermal port') && ~startsWith(modeling, 'no')
            assessment = 'NONLINEAR';
            reason = [rule.Reason ' However, the thermal port is exposed: the element value ' ...
                'then depends on temperature, which depends on dissipated power, so the ' ...
                'electrical behavior is no longer linear.'];
            return
        end
        if strcmp(rule.Check, 'ee_capacitor')
            [kind, raw, how] = capacitanceModel(params);
            switch kind
                case 'table'
                    assessment = 'NONLINEAR';
                    reason = sprintf('%s Capacitance model = Lookup table (raw value "%s", %s): C depends on the voltage.', ...
                        rule.Reason, raw, how);
                case 'debye'
                    assessment = 'LINEAR';
                    reason = sprintf(['%s Capacitance model = Dielectric relaxation (Debye) (raw value "%s", %s): ' ...
                        'frequency-dependent but still linear (it adds internal states).'], rule.Reason, raw, how);
                case 'constant'
                    assessment = 'LINEAR';
                    reason = sprintf('%s Capacitance model = Constant (raw value "%s", %s): i = C*dv/dt.', ...
                        rule.Reason, raw, how);
                otherwise
                    assessment = 'UNKNOWN';
                    reason = sprintf(['%s Could not interpret the Capacitance model value "%s". ' ...
                        'Please report this value so the rule can be extended.'], rule.Reason, raw);
                    return
            end
        end
        notes = commonNotes(params, notes);
    case 'ee_source'
        notes = commonNotes(params, notes);
end
if ~isempty(notes)
    reason = sprintf('%s Note: %s.', reason, strjoin(notes, '; '));
end
end

function [kind, raw, how] = capacitanceModel(params)
% Works out which Capacitance model a Simscape Electrical Capacitor uses.
% In R2026b the parameter is "cap_option" and its value is an enumeration
% such as "ee.enum.passive.capacitor.capOption.const". Only the last part of
% the enumeration name ("const") identifies the option, so that part is
% matched first; then the whole text; then a numeric dropdown index.
kind = '';
how = '';
[raw, found] = paramValue(params, {'cap_option', 'capacitance_model', 'cap_model'}, ...
    {'Capacitance model', 'Capacitor type'});
if ~found
    raw = '';
    kind = 'constant';
    how = 'no "Capacitance model" option in this release, constant assumed';
    return
end
lc = lower(strtrim(raw));
parts = strsplit(lc, '.');
member = parts{end};                            % e.g. 'const'
kind = classifyCapOption(member);
if ~isempty(kind)
    how = sprintf('enumeration member "%s"', member);
    return
end
kind = classifyCapOption(lc);
if ~isempty(kind)
    how = 'matched by keyword';
    return
end
tok = regexp(lc, '(\d+)\s*\)?\s*$', 'tokens', 'once');
if ~isempty(tok)
    order = {'constant', 'table', 'debye'};      % documented dropdown order
    n = str2double(tok{1});
    if n >= 1 && n <= 3
        kind = order{n};
        how = 'matched by dropdown position (Constant, Lookup table, Debye)';
    end
end
end

function kind = classifyCapOption(txt)
kind = '';
if contains(txt, {'table', 'lookup', 'tabulated', 'lut', 'nonlin', 'cv'})
    kind = 'table';
elseif contains(txt, {'debye', 'relax', 'dielectric', 'freq'})
    kind = 'debye';
elseif contains(txt, {'const', 'fixed', 'ideal', 'linear', 'nominal'})
    kind = 'constant';
end
end

function notes = commonNotes(params, notes)
% R2026b values: noise_mode = ee.enum.sources.noise.Disabled,
% enable_R_tol / enable_C_tol = ee.enum.toleranceApplication.none
noise = lower(paramValue(params, {'noise_mode'}, {'Noise mode'}));
if contains(noise, 'enable') && ~contains(noise, 'disable')
    notes{end + 1} = 'noise is enabled (an additive random source; superposition still holds)';
end
tol = lower(paramValue(params, {'enable_R_tol', 'enable_C_tol', 'enable_L_tol'}, ...
    {'Tolerance application'}));
if contains(tol, 'random')
    notes{end + 1} = 'random tolerance is applied (the value is fixed within one run)';
end
end

function [value, found, unit] = paramValue(params, names, prompts)
% Look up a parameter by its programmatic name first (column 1, exact,
% case-sensitive, e.g. 'cap_option'), then by its dialog prompt.
value = '';
unit = '';
found = false;
for n = 1:numel(names)
    k = find(strcmp(params(:, 1), names{n}), 1);
    if ~isempty(k)
        value = params{k, 3};
        unit = params{k, 4};
        found = true;
        return
    end
end
for n = 1:numel(prompts)
    [value, found, unit] = promptValue(params, prompts{n});
    if found
        return
    end
end
end

function [value, found, unit] = promptValue(params, prompt)
% Look up a dialog parameter by its visible prompt (case-insensitive,
% trailing colon ignored). Exact match only, so "Capacitance" does not
% match "Capacitance model".
value = '';
unit = '';
found = false;
target = normPrompt(prompt);
for k = 1:size(params, 1)
    if strcmp(normPrompt(params{k, 2}), target)
        value = params{k, 3};
        unit = params{k, 4};
        found = true;
        return
    end
end
end

function s = normPrompt(s)
s = lower(strtrim(regexprep(char(s), '[:\s]+$', '')));
end

function txt = valueSummary(rule, params)
parts = {};
for k = 1:numel(rule.ValuePrompts)
    [v, found, u] = promptValue(params, rule.ValuePrompts{k});
    if found
        if isempty(u)
            parts{end + 1} = sprintf('%s=%s', rule.ValuePrompts{k}, v); %#ok<AGROW>
        else
            parts{end + 1} = sprintf('%s=%s %s', rule.ValuePrompts{k}, v, u); %#ok<AGROW>
        end
    end
end
txt = strjoin(parts, '; ');
end

function rows = getDialogParams(h)
% Returns {Name, Prompt, Value, Unit} rows. Values are the raw expressions
% exactly as typed in the dialog (for example 'R_nominal'), not evaluated.
rows = cell(0, 4);
try
    dp = get_param(h, 'DialogParameters');
catch
    return
end
if isempty(dp) || ~isstruct(dp)
    return
end
names = fieldnames(dp);
for k = 1:numel(names)
    nm = names{k};
    if endsWith(nm, '_unit') && isfield(dp, nm(1:end - 5))
        continue                    % reported in the Unit column of its parameter
    end
    info = dp.(nm);
    prompt = '';
    if isstruct(info) && isfield(info, 'Prompt')
        prompt = cleanText(valueToText(info.Prompt));
    end
    try
        val = valueToText(get_param(h, nm));
    catch
        val = '<unreadable>';
    end
    if isstruct(info) && isfield(info, 'Type') && strcmpi(info.Type, 'enum') ...
            && isfield(info, 'Enum') && iscell(info.Enum) && ~any(strcmp(val, info.Enum))
        n = str2double(val);
        if isfinite(n) && n == round(n) && n >= 1 && n <= numel(info.Enum)
            val = sprintf('%s [%s]', val, info.Enum{n});   % index -> option text
        end
    end
    unit = '';
    if isfield(dp, [nm '_unit'])
        try
            unit = valueToText(get_param(h, [nm '_unit']));
        catch
        end
    end
    rows(end + 1, :) = {nm, prompt, cleanText(val), unit}; %#ok<AGROW>
end
end

function [term, src] = terminalName(rule, group, idx)
term = '';
src = '';
if isempty(rule.Terminals)
    return
end
k = find(strcmp(rule.Terminals(:, 1), sprintf('%s%d', group, idx)), 1);
if ~isempty(k)
    term = rule.Terminals{k, 2};
    src = 'library rule';
end
end

function s = portLabel(c, group, idx)
[term, ~] = terminalName(c.Rule, group, idx);
who = c.Designator;
if isempty(who)
    who = c.Name;
end
if isempty(term)
    s = sprintf('%s.%s%d', who, group, idx);
else
    s = sprintf('%s.%s', who, term);
end
end

function [classification, explanation] = overallClassification(comp, isRealComp)
idx = find(isRealComp);
a = {comp(idx).Assessment};
nonlin = idx(strcmp(a, 'NONLINEAR'));
unknown = idx(strcmp(a, 'UNKNOWN'));
linear = idx(strcmp(a, 'LINEAR'));
sources = idx(strcmp(a, 'SOURCE'));
if ~isempty(nonlin)
    classification = 'NONLINEAR_COMPONENTS_PRESENT';
    explanation = sprintf('Nonlinear element(s): %s.', listNames(comp(nonlin)));
elseif ~isempty(unknown)
    classification = 'UNKNOWN';
    explanation = sprintf(['No nonlinear element was recognized, but these blocks have not been ' ...
        'reviewed: %s. See the Reason column.'], listNames(comp(unknown)));
elseif ~isempty(linear)
    classification = 'LINEAR_CANDIDATE';
    explanation = sprintf(['All %d circuit element(s) are recognized linear elements in their ' ...
        'current configuration; %d source(s) are treated as external forcing. This assumes ' ...
        'fixed parameter values and no active faults.'], numel(linear), numel(sources));
else
    classification = 'UNKNOWN';
    explanation = 'No recognized circuit element (R, L, C, ...) was found in the model.';
end
end

function s = listNames(cs)
names = cell(1, numel(cs));
for k = 1:numel(cs)
    if isempty(cs(k).Designator)
        names{k} = cs(k).Name;
    else
        names{k} = sprintf('%s (%s)', cs(k).Designator, cs(k).Name);
    end
end
s = strjoin(names, ', ');
end

function t = componentTable(comp)
n = numel(comp);
rows = cell(n, 20);
for c = 1:n
    p = comp(c).Position;
    rows(c, :) = {comp(c).ID, comp(c).Designator, comp(c).Name, comp(c).Path, ...
        comp(c).Parent, comp(c).BlockType, comp(c).ReferenceBlock, comp(c).ComponentPath, ...
        comp(c).Role, comp(c).Domain, comp(c).Assessment, comp(c).Reason, comp(c).Network, ...
        (p(1) + p(3)) / 2, (p(2) + p(4)) / 2, p(1), p(2), p(3), p(4), comp(c).Orientation};
end
t = makeTable(rows, {'ComponentID', 'Designator', 'Name', 'Path', 'Parent', 'BlockType', ...
    'ReferenceBlock', 'ComponentPath', 'Role', 'Domain', 'Assessment', 'Reason', 'Network', ...
    'CenterX', 'CenterY', 'Left', 'Top', 'Right', 'Bottom', 'Orientation'});
end

function t = makeTable(rows, names)
if isempty(rows)
    rows = cell(0, numel(names));
end
t = cell2table(rows, 'VariableNames', names);
end

function p = physicalPorts(h)
ph = get_param(h, 'PortHandles');
p = double([ph.LConn(:); ph.RConn(:)]).';
end

function v = firstParam(h, names)
v = '';
for k = 1:numel(names)
    try
        v = valueToText(get_param(h, names{k}));
        if ~isempty(v)
            return
        end
    catch
    end
end
end

function v = getParamOr(h, name, default)
try
    v = get_param(h, name);
catch
    v = default;
end
end

function s = safeFullName(h)
try
    s = cleanText(getfullname(h));
catch
    s = sprintf('<handle %g>', h);
end
end

function s = valueToText(v)
if ischar(v)
    s = v;
elseif isstring(v)
    s = char(strjoin(v, ', '));
elseif isnumeric(v) || islogical(v)
    s = mat2str(v);
elseif iscell(v)
    s = strjoin(cellfun(@valueToText, v, 'UniformOutput', false), ', ');
else
    s = sprintf('<%s>', class(v));
end
end

function s = cleanText(s)
s = strtrim(regexprep(char(s), '[\r\n\t]+', ' '));
end

function loc = codeLocation(ME)
% "inspectCircuit>localFunction, line 123" for the frame that threw.
loc = '';
if ~isempty(ME.stack)
    [~, f, e] = fileparts(ME.stack(1).file);
    loc = sprintf('%s%s > %s, line %d', f, e, ME.stack(1).name, ME.stack(1).line);
end
end
