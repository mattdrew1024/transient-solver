function files = writeInspectionReport(report, outputFolder)
%WRITEINSPECTIONREPORT  Write an inspectCircuit report as CSV files.
%
%   files = writeInspectionReport(report, outputFolder)
%
%   Writes one CSV per table and returns their full paths:
%     summary.csv     overall classification and counts (1 row)
%     components.csv  one row per block: position, role, linearity verdict
%     ports.csv       one row per port: terminal, NetID, electrical NodeID
%     nets.csv        one row per connected net and its member terminals
%     netlist.csv     two-terminal electrical elements: + node, - node, value
%     parameters.csv  every dialog parameter (raw expressions, units)
%     warnings.csv    issues found while inspecting
%
%   How the files relate:
%     components.ComponentID  <- ports.ComponentID, parameters.ComponentID,
%                                netlist.ComponentID, warnings.ComponentID
%     ports.NetID             <- nets.NetID
%     ports.NodeID / netlist.PositiveNode / NegativeNode: electrical node
%                                names; "0" is ground (every Electrical Reference).

if nargin < 2 || isempty(outputFolder)
    error('writeInspectionReport:noFolder', 'No output folder was given.');
end
if ~isfolder(outputFolder)
    [ok, msg] = mkdir(outputFolder);
    if ~ok
        error('writeInspectionReport:mkdirFailed', ...
            'Could not create output folder "%s": %s', outputFolder, msg);
    end
end

parts = {
    'Summary',    'summary.csv'
    'Components', 'components.csv'
    'Ports',      'ports.csv'
    'Nets',       'nets.csv'
    'Netlist',    'netlist.csv'
    'Parameters', 'parameters.csv'
    'Warnings',   'warnings.csv'
    };

files = cell(size(parts, 1), 1);
for k = 1:size(parts, 1)
    field = parts{k, 1};
    files{k} = fullfile(outputFolder, parts{k, 2});
    if ~isfield(report, field)
        error('writeInspectionReport:missingTable', ...
            'The report has no "%s" table. Was it produced by inspectCircuit?', field);
    end
    try
        writetable(report.(field), files{k});
    catch ME
        err = MException('writeInspectionReport:writeFailed', ...
            'Could not write %s (is it open in Excel?): %s', files{k}, ME.message);
        throw(addCause(err, ME));
    end
end
end
