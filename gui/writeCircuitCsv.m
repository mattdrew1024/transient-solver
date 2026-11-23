function csvFile = writeCircuitCsv(circuit, csvFile)
%WRITECIRCUITCSV  Write the circuit CSV read by the transient solver.
%
%   csvFile = writeCircuitCsv(circuit, csvFile)
%
%   circuit  table with exactly these columns, in this order (the Netlist
%            table returned by inspectCircuit, possibly edited in the app):
%              Designator,Type,NodePos,NodeNeg,Value,Waveform,Amplitude,
%              Frequency,Phase,IC,Sensitivity,Expression,Derivative
%   csvFile  output file, e.g. 'test_circuits/lasha_path0.csv'
%
%   One row per part. Every cell is written as plain text; empty cells are
%   written as nothing (",,"), which the solver reads as "not used" or its
%   default (Waveform DC, Phase 0, IC 0, Sensitivity 0). Values are in SI
%   units: Ohm, F, H, V, A, Hz, rad. Ground is node 0.
%
%   Example (Lasha's Path 0 circuit):
%     Designator,Type,NodePos,NodeNeg,Value,Waveform,Amplitude,Frequency,Phase,IC,Sensitivity,Expression,Derivative
%     V1,V,n1,0,6,DC,,,,,,,
%     R1,R,n1,n2,0.2,,,,,,1,,
%     R2,R,n2,0,0.3333,,,,,,1,,

columns = {'Designator', 'Type', 'NodePos', 'NodeNeg', 'Value', 'Waveform', ...
    'Amplitude', 'Frequency', 'Phase', 'IC', 'Sensitivity', 'Expression', 'Derivative'};

if ~istable(circuit)
    error('writeCircuitCsv:notTable', 'The circuit must be a table.');
end
if ~isequal(circuit.Properties.VariableNames, columns)
    error('writeCircuitCsv:columns', ['The circuit table must have the columns\n  %s\n' ...
        'in that order, but has\n  %s'], strjoin(columns, ','), ...
        strjoin(circuit.Properties.VariableNames, ','));
end
csvFile = char(csvFile);
folder = fileparts(csvFile);
if ~isempty(folder) && ~isfolder(folder)
    [ok, msg] = mkdir(folder);
    if ~ok
        error('writeCircuitCsv:mkdir', 'Could not create %s: %s', folder, msg);
    end
end

% Check the rows before writing, so a bad file is never produced.
des = cellText(circuit.Designator);
dup = unique(des(cellfun(@(d) nnz(strcmp(des, d)) > 1, des)));
if ~isempty(dup)
    error('writeCircuitCsv:duplicate', 'Designators must be unique; repeated: %s', ...
        strjoin(dup, ', '));
end
types = cellText(circuit.Type);
bad = ~ismember(types, {'R', 'C', 'L', 'V', 'I', 'NL', 'IC'});
if any(bad)
    error('writeCircuitCsv:type', 'Unknown Type in row(s) %s. Allowed: R, C, L, V, I, NL, IC.', ...
        mat2str(find(bad)'));
end

nodes = [cellText(circuit.NodePos), cellText(circuit.NodeNeg)];
open_ = any(strcmp(nodes, '?'), 2);
if any(open_)
    error('writeCircuitCsv:unconnected', ['%s has an unconnected terminal (node "?"). ' ...
        'Connect it in the model and inspect again.'], strjoin(des(open_), ', '));
end

fid = fopen(csvFile, 'w');
if fid < 0
    error('writeCircuitCsv:open', 'Could not open %s for writing.', csvFile);
end
closer = onCleanup(@() fclose(fid));
fprintf(fid, '%s\n', strjoin(columns, ','));
for r = 1:height(circuit)
    cells = cell(1, numel(columns));
    for k = 1:numel(columns)
        v = circuit{r, k};
        if iscell(v)
            v = v{1};
        end
        cells{k} = csvField(v);
    end
    fprintf(fid, '%s\n', strjoin(cells, ','));
end
clear closer
end

% ---------------------------------------------------------------------

function c = cellText(col)
if iscell(col)
    c = cellfun(@(x) strtrim(char(string(x))), col, 'UniformOutput', false);
else
    c = cellstr(strtrim(string(col)));
end
end

function s = csvField(v)
if isempty(v) || (isnumeric(v) && isnan(v)) || (isstring(v) && ismissing(v))
    s = '';
elseif isnumeric(v) || islogical(v)
    s = sprintf('%.15g', double(v));
else
    s = strtrim(char(string(v)));
end
if any(s == ',') || any(s == '"')
    s = ['"' strrep(s, '"', '""') '"'];   % e.g. a MATLAB expression with commas
end
end
