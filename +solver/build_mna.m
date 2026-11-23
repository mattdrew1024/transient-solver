function mna = build_mna(circuit)
%BUILD_MNA  Turn the GUI's circuit CSV into the inputs of runSolver.
%
%   mna = solver.build_mna('tests/test_circuits/lasha_path0.csv')
%   mna = solver.build_mna(T)          % T from solver.readCircuitCsv
%
%   Supports Type = R, C, L, V, I and IC rows. NL (diodes) is not done yet.
%
%   Convention (same as testRun.mlx):  G*x + C*dx/dt + F(x) = B(t)
%   x = [node voltages (n1, n2, ...); one current for each V source and each L]
%
%   Sensitivity parameters are the rows with Sensitivity = 1, in CSV order:
%       R: p = g = 1/R     C: p = c     L: p = Y = 1/L
%
%   Output fields: C, dCxdp, G, dGxdp, F, dFdx, B, lnth, x0, names, params
%   lnth = [length(x), number of parameters]
%
%   BIG PICTURE
%   Lasha's runSolver does not know what a resistor or a capacitor is. It only
%   takes matrices. This function is the translator: it goes through the CSV
%   one part at a time, and each part adds ("stamps") its own small pattern of
%   numbers into the big matrices. The steps are:
%     1. read the CSV columns
%     2. number the unknowns (which entry of x is which node or current)
%     3. stamp every part into G, C and B
%     4. build the initial values x0
%     5. build the sensitivity rows (dGxdp, dCxdp)
%     6. pack everything into the struct that runSolver needs

    % ---- step 1: get the CSV as a table ----
    % Accept either a file path or a table that readCircuitCsv already made.
    if ischar(circuit) || isstring(circuit)
        T = solver.readCircuitCsv(char(circuit));
    else
        T = circuit;
    end

    % Pull each CSV column out as a column of text. Blank cells become "".
    % pos/neg are the two terminals of each part (NodePos / NodeNeg).
    n    = height(T);
    des  = col(T, 'Designator', n, true);
    typ  = upper(col(T, 'Type', n, true));
    pos  = nodeName(col(T, 'NodePos', n, true));
    neg  = nodeName(col(T, 'NodeNeg', n, false));
    val  = col(T, 'Value', n, false);
    wave = upper(col(T, 'Waveform', n, false));
    amps = col(T, 'Amplitude', n, false);
    freq = col(T, 'Frequency', n, false);
    phs  = col(T, 'Phase', n, false);
    ic   = col(T, 'IC', n, false);
    sens = col(T, 'Sensitivity', n, false);

    isIC = (typ == "IC");   % IC rows only set a starting voltage, they are not real parts

    % ---- step 2: number the unknowns ----
    % x is the list of things we solve for. Its order is:
    %   [ v(n1); v(n2); ...;   current of each V source and each inductor ]
    % Ground (node "0") is the reference, so it is NOT an unknown.
    % Every part except IC rows needs two terminals.
    for i = find(~isIC & neg == "")'
        error('build_mna:node', '%s has no NodeNeg.', des(i));
    end
    % Collect every distinct node name used by the parts, drop ground, and sort
    % them naturally (n1, n2, ..., n10). Position in this list = row in x.
    allNodes = [pos(~isIC); neg(~isIC)];
    allNodes = unique(allNodes(allNodes ~= "0"), 'stable');
    nodeNames = naturalSort(allNodes);
    nNode = numel(nodeNames);

    % A voltage source or inductor forces a current we do not know, so each one
    % gets one extra unknown after the node voltages. curIdx(i) is the row of
    % part i's current in x (0 for parts that have none).
    curRows = find(typ == "V" | typ == "L");
    curIdx  = zeros(n, 1);
    curIdx(curRows) = nNode + (1:numel(curRows))';
    nx = nNode + numel(curRows);            % total number of unknowns

    names = cell(nx, 1);
    for k = 1:nNode
        names{k} = sprintf('v(%s)', nodeNames(k));
    end
    for i = curRows'
        names{curIdx(i)} = sprintf('i(%s)', des(i));
    end

    % H(i) and L(i) = the row in x of part i's positive and negative node.
    % 0 means that terminal is ground. IC rows only have a positive node.
    H = zeros(n, 1);  L = zeros(n, 1);
    for i = 1:n
        H(i) = idxOf(pos(i), nodeNames, des(i));
        if ~isIC(i)
            L(i) = idxOf(neg(i), nodeNames, des(i));
        end
    end

    % ---- step 3: stamp every part ----
    % The circuit equation is   G*x + C*dx/dt = B(t)   (plus F(x) for nonlinear).
    %   G = resistor-like terms (and the wiring of sources and inductors)
    %   C = storage terms (capacitors and inductors)
    %   B = what the independent sources push in
    % Each part only touches a few entries. "Stamping" = adding those entries.
    G  = zeros(nx);
    Cm = zeros(nx);  hasC = false;
    % Each B row is {stampVector, value or @(t), isTimeVarying}: the source's
    % value times the stamp vector is added to the right-hand side.
    B  = cell(0, 3);
    for i = 1:n
        switch typ(i)
            case "R"
                % Resistor between H and L, conductance g = 1/R:
                %           H    L
                %      H  [ +g   -g ]
                %      L  [ -g   +g ]
                % (the entries for ground are skipped by addTo)
                R = numReq(val(i), des(i), 'Value');
                if R == 0
                    error('build_mna:zeroR', '%s has R = 0.', des(i));
                end
                g = 1/R;
                G = addTo(G, H(i), H(i), +g);
                G = addTo(G, L(i), L(i), +g);
                G = addTo(G, H(i), L(i), -g);
                G = addTo(G, L(i), H(i), -g);

            case "C"
                % Capacitor: same pattern as a resistor, but with the
                % capacitance c and in the C matrix (current = c * dv/dt).
                c = numReq(val(i), des(i), 'Value');
                Cm = addTo(Cm, H(i), H(i), +c);
                Cm = addTo(Cm, L(i), L(i), +c);
                Cm = addTo(Cm, H(i), L(i), -c);
                Cm = addTo(Cm, L(i), H(i), -c);
                hasC = true;

            case "L"
                % The inductor's current is an unknown (row k of x).
                % Its own equation is  v(H) - v(L) = Lh * di/dt, written with
                % Y = 1/Lh so that the parameter is Y:
                %   row k:  di/dt - Y*v(H) + Y*v(L) = 0
                % and the current k leaves node H and enters node L (+1 / -1 below).
                Lh = numReq(val(i), des(i), 'Value');
                if Lh == 0
                    error('build_mna:zeroL', '%s has L = 0.', des(i));
                end
                Y = 1/Lh;  k = curIdx(i);
                Cm = addTo(Cm, k, k, +1);
                G  = addTo(G, k, H(i), -Y);
                G  = addTo(G, k, L(i), +Y);
                G  = addTo(G, H(i), k, +1);
                G  = addTo(G, L(i), k, -1);
                hasC = true;

            case "V"
                % Voltage source: its current is an unknown (row k of x).
                % The extra equation is  v(H) - v(L) = source value, so the
                % source value goes on the right-hand side (B) at row k.
                k = curIdx(i);
                G = addTo(G, H(i), k, +1);
                G = addTo(G, k, H(i), +1);
                G = addTo(G, L(i), k, -1);
                G = addTo(G, k, L(i), -1);
                sv = zeros(nx, 1);  sv(k) = 1;
                [v, isTV] = sourceValue(i, des, val, wave, amps, freq, phs);
                B(end+1, :) = {sv, v, isTV};         %#ok<AGROW>

            case "I"
                % Current flows through the source from NodeNeg to NodePos,
                % so it is injected into NodePos: B(H) = +I, B(L) = -I.
                sv = zeros(nx, 1);
                if H(i) > 0, sv(H(i)) = +1; end
                if L(i) > 0, sv(L(i)) = -1; end
                [v, isTV] = sourceValue(i, des, val, wave, amps, freq, phs);
                B(end+1, :) = {sv, v, isTV};         %#ok<AGROW>

            case "IC"
                % handled below (initial values)

            case "NL"
                error('build_mna:unsupported', ...
                    '%s: NL parts (diodes) are not supported yet.', des(i));

            otherwise
                error('build_mna:type', '%s: unknown Type "%s".', des(i), typ(i));
        end
    end

    % ---- step 4: initial values x0 (default all zeros) ----
    % x0 is the value of every unknown at t = 0. Sources of initial values:
    %   - IC column of a capacitor: its starting voltage (needs one terminal on ground)
    %   - IC column of an inductor: its starting current
    %   - a Type = IC row: starting voltage of that node
    x0 = zeros(nx, 1);
    for i = 1:n
        switch typ(i)
            case "C"
                if ic(i) ~= ""
                    v0 = numReq(ic(i), des(i), 'IC');
                    if L(i) == 0 && H(i) > 0
                        x0(H(i)) = v0;
                    elseif H(i) == 0 && L(i) > 0
                        x0(L(i)) = -v0;
                    else
                        error('build_mna:ic', ...
                            '%s: IC on a capacitor needs one terminal on ground (use IC rows instead).', des(i));
                    end
                end
            case "L"
                if ic(i) ~= ""
                    x0(curIdx(i)) = numReq(ic(i), des(i), 'IC');
                end
            case "IC"
                if H(i) == 0
                    error('build_mna:ic', '%s: IC row on ground makes no sense.', des(i));
                end
                x0(H(i)) = numReq(val(i), des(i), 'Value');
        end
    end

    % ---- step 5: sensitivity rows ----
    % One row for every part with Sensitivity = 1, in CSV order.
    % dGxdp(j,:) is how G changes with parameter j (times x), dCxdp(j,:) the same
    % for C. Each row is {stamp, [a b]}: assemble.m later computes
    %     stamp * (x(a) - x(b))
    % at each time step. A parameter that is not in G gets a zero stamp there
    % ({zeros, [0 0]}), as Lasha's README asks.
    % assemble.m misbehaves if the first index a is ground, so pairStamp swaps
    % the pair and flips the sign when that happens (same value either way).
    pRows = [];
    for i = 1:n
        if sens(i) ~= "" && numReq(sens(i), des(i), 'Sensitivity') == 1
            if ~ismember(typ(i), ["R" "C" "L"])
                error('build_mna:param', ...
                    '%s: Sensitivity = 1 is only for R, C or L parts.', des(i));
            end
            pRows(end+1) = i;                        %#ok<AGROW>
        end
    end
    np = numel(pRows);
    dGxdp = cell(np, 2);
    dCxdp = cell(np, 2);
    zero  = {zeros(nx, 1), [0, 0]};
    for j = 1:np
        i = pRows(j);
        sv = zeros(nx, 1);
        switch typ(i)
            case "R"                                 % p = g
                if H(i) > 0, sv(H(i)) = +1; end
                if L(i) > 0, sv(L(i)) = -1; end
                dGxdp(j, :) = pairStamp(sv, H(i), L(i));
                dCxdp(j, :) = zero;
            case "C"                                 % p = c
                if H(i) > 0, sv(H(i)) = +1; end
                if L(i) > 0, sv(L(i)) = -1; end
                dCxdp(j, :) = pairStamp(sv, H(i), L(i));
                dGxdp(j, :) = zero;
            case "L"                                 % p = Y: d/dY of row k = -(v(H) - v(L))
                sv(curIdx(i)) = -1;
                dGxdp(j, :) = pairStamp(sv, H(i), L(i));
                dCxdp(j, :) = zero;
        end
    end

    % ---- step 6: pack the runSolver inputs ----
    % If the circuit has no capacitors or inductors, C and dCxdp are the number 0,
    % which is what Lasha's Path 0 example passes.
    if hasC
        mna.C     = Cm;
        mna.dCxdp = dCxdp;
    else
        mna.C     = 0;           % Path 0 / 1 pass 0 here
        mna.dCxdp = 0;
    end
    mna.G      = G;
    mna.dGxdp  = dGxdp;
    mna.F      = 0;              % no nonlinear parts yet
    mna.dFdx   = 0;
    mna.B      = B;
    mna.lnth   = [nx, np];
    mna.x0     = x0;
    mna.names  = names;
    mna.params = cellstr(des(pRows));
end

% ======================= local helpers =======================

function s = col(T, name, n, required)
%COL  Column of T as a string vector. Blank or missing cells become "".
    if ~ismember(name, T.Properties.VariableNames)
        if required
            error('build_mna:columns', 'Circuit table has no column "%s".', name);
        end
        s = strings(n, 1);
        return
    end
    s = string(T.(name));
    s(ismissing(s)) = "";
    s = strip(s);
end

function s = nodeName(s)
%NODENAME  Ground can be written 0, gnd or ground; it becomes "0".
%   Any other name (n1, out, ...) is a normal node and is left alone.
    isG = lower(s) == "gnd" | lower(s) == "ground";
    s(isG) = "0";
end

function i = idxOf(name, nodeNames, des)
%IDXOF  Row in x of a node name. Ground ("0") returns 0.
    if name == "0"
        i = 0;
        return
    end
    i = find(nodeNames == name, 1);
    if isempty(i)
        error('build_mna:node', '%s: unknown node "%s".', des, name);
    end
end

function G = addTo(G, i, j, v)
%ADDTO  Add v at (i,j). Anything touching ground (index 0) is left out.
    if i > 0 && j > 0
        G(i, j) = G(i, j) + v;
    end
end

function row = pairStamp(sv, H, L)
%PAIRSTAMP  {stamp, [a b]} meaning stamp*(x(a) - x(b)), with a never ground.
%   If H is ground, swap the pair and flip the sign (same value).
    if H == 0
        row = {-sv, [L, 0]};
    else
        row = {sv, [H, L]};
    end
end

function v = numReq(s, des, what)
%NUMREQ  Number from text. Accepts plain numbers and simple fractions like 1/3.
    v = str2double(s);
    if isnan(v)
        t = regexp(char(s), '^\s*([-+0-9.eE]+)\s*/\s*([-+0-9.eE]+)\s*$', 'tokens', 'once');
        if ~isempty(t)
            v = str2double(t{1}) / str2double(t{2});
        end
    end
    if isnan(v)
        error('build_mna:notNumber', '%s: %s ("%s") is not a number.', des, what, s);
    end
end

function v = numOr(s, des, what, default)
    if s == ""
        v = default;
    else
        v = numReq(s, des, what);
    end
end

function [v, isTV] = sourceValue(i, des, val, wave, amps, freq, phs)
%SOURCEVALUE  DC value, or @(t) for a SIN source, plus the isTimeVarying flag.
    dc = numOr(val(i), des(i), 'Value', 0);
    if wave(i) == "" || wave(i) == "DC"
        v = dc;  isTV = false;
    elseif wave(i) == "SIN" || wave(i) == "SINE"
        amp = numReq(amps(i), des(i), 'Amplitude');
        f   = numReq(freq(i), des(i), 'Frequency');
        ph  = numOr(phs(i), des(i), 'Phase', 0);
        v = @(t) dc + amp*sin(2*pi*f*t + ph);
        isTV = true;
    else
        error('build_mna:waveform', '%s: unknown Waveform "%s".', des(i), wave(i));
    end
end

function s = naturalSort(s)
%NATURALSORT  n1, n2, ..., n10 (not n1, n10, n2). Falls back to plain sort.
    if isempty(s), return, end
    tok = regexp(cellstr(s), '^(\D*)(\d+)$', 'tokens', 'once');
    if all(~cellfun(@isempty, tok))
        pre = cellfun(@(t) t{1}, tok, 'UniformOutput', false);
        num = cellfun(@(t) str2double(t{2}), tok);
        [~, order] = sortrows(table(pre(:), num(:)));
        s = s(order);
    else
        s = sort(s);
    end
end
