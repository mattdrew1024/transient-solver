function circuitInspectorActions(action, app)
%CIRCUITINSPECTORACTIONS  Behavior behind the CircuitInspectorApp buttons.
%
%   circuitInspectorActions(action, app)
%     action: 'startup' | 'select' | 'inspect' | 'export' | 'opendiagram'
%     app:    the running CircuitInspectorApp
%
%   The App Designer callbacks are one-liners that call this function, so
%   the behavior lives in a normal .m file: it can be diffed, debugged with
%   breakpoints, and reused unchanged whether the app is stored as .mlapp or
%   in App Designer's plain-text format.
%
%   The app must have these components: UIFigure, SelectModelButton,
%   InspectButton, ExportButton, ModelPathLabel, ClassificationLabel,
%   ComponentsTable, PortsTable, NetsTable, NetlistTable, WarningsTable,
%   MessagesTextArea, and public properties ModelFile and Report.
%
%   The "Diagram" tab (picture of the selected model, so you can check it is
%   the right file) is created by this file at startup, inside
%   ResultsTabGroup, so the app itself does not need to be edited. Its
%   components are found again through their Tag values (see diagramUi).

try
    switch lower(char(action))
        case 'startup'
            startup(app);
        case 'select'
            selectModel(app);
        case 'inspect'
            inspect(app);
        case 'export'
            exportCsv(app);
        case 'opendiagram'
            openInSimulink(app);
        otherwise
            error('circuitInspectorActions:unknownAction', 'Unknown action "%s".', char(action));
    end
catch ME
    showError(app, ME, sprintf('"%s" failed', char(action)));
end
end

% ---------------------------------------------------------------------

function startup(app)
app.ModelFile = '';
app.Report = [];
app.InspectButton.Enable = 'off';
app.ExportButton.Enable = 'off';
app.ModelPathLabel.Text = 'No model selected.';
setResult(app, 'Result: not inspected yet', [0.3 0.3 0.3]);
clearTables(app);
ensureDiagramTab(app);
clearDiagram(app, 'Select a model to see its diagram here.');

msgs = {'1. Select Model: choose your Simulink/Simscape model (.slx or .mdl).'
    '2. Inspect: list components, ports, nets and the netlist, and check linearity.'
    '3. Export CSV: save the Netlist tab as one circuit CSV for the solver.'};
if exist('inspectCircuit', 'file') ~= 2
    msgs{end + 1} = ['WARNING: inspectCircuit.m is not on the MATLAB path. ' ...
        'Run addpath(''<repo>/gui'') before inspecting.'];
end
if ~license('test', 'Simscape')
    msgs{end + 1} = 'WARNING: no Simscape license was found; Simscape models will not load.';
end
app.MessagesTextArea.Value = msgs;
end

function selectModel(app)
startFolder = pwd;
if ~isempty(app.ModelFile)
    startFolder = fileparts(app.ModelFile);
end
[f, p] = uigetfile({'*.slx;*.mdl', 'Simulink models (*.slx, *.mdl)'}, ...
    'Select a Simscape model', startFolder);
figure(app.UIFigure);               % file dialogs can push the app behind MATLAB
if isequal(f, 0)
    return
end
app.ModelFile = fullfile(p, f);
app.Report = [];
app.ModelPathLabel.Text = app.ModelFile;
app.InspectButton.Enable = 'on';
app.ExportButton.Enable = 'off';
clearTables(app);
setResult(app, 'Result: not inspected yet', [0.3 0.3 0.3]);
app.MessagesTextArea.Value = {sprintf('Selected %s. Click "2. Inspect".', f)};
showDiagram(app);
end

function inspect(app)
if isempty(app.ModelFile)
    uialert(app.UIFigure, 'Select a model first.', 'No model');
    return
end
[~, name, ext] = fileparts(app.ModelFile);
app.Report = [];
app.ExportButton.Enable = 'off';
clearTables(app);
d = uiprogressdlg(app.UIFigure, 'Title', 'Inspecting', 'Indeterminate', 'on', ...
    'Message', sprintf('Loading and inspecting %s%s ...', name, ext));
try
    report = inspectCircuit(app.ModelFile);
catch ME
    closeDialog(d);
    setResult(app, 'Result: inspection failed (see Messages)', [0.75 0 0]);
    showError(app, ME, 'Inspection failed');
    return
end
closeDialog(d);
app.Report = report;
showReport(app);
app.ExportButton.Enable = 'on';
end

function exportCsv(app)
% Writes ONE file: the circuit CSV, taken from the Netlist tab, so edits
% made there (Sensitivity, IC, Expression, Derivative) are included.
if isempty(app.Report)
    uialert(app.UIFigure, 'Inspect a model before exporting.', 'Nothing to export');
    return
end
[folder, name] = fileparts(app.ModelFile);
[f, p] = uiputfile({'*.csv', 'Circuit CSV (*.csv)'}, 'Save the circuit CSV', ...
    fullfile(folder, [name '.csv']));
figure(app.UIFigure);
if isequal(f, 0)
    return
end
target = fullfile(p, f);
writeCircuitCsv(app.NetlistTable.Data, target);
n = height(app.NetlistTable.Data);
app.MessagesTextArea.Value = {sprintf('Wrote %d parts to %s', n, target)};
uialert(app.UIFigure, sprintf('Wrote %d parts to\n%s', n, target), ...
    'Export complete', 'Icon', 'success');
end

% ---------------------------------------------------------------------

function showReport(app)
r = app.Report;
app.ComponentsTable.Data = r.Components;
app.PortsTable.Data = r.Ports;
app.NetsTable.Data = r.Nets;
app.NetlistTable.Data = r.Netlist;
% Columns the model cannot provide are editable here before export:
% Sensitivity (1 = sensitivity parameter), IC, Expression, Derivative.
cols = r.Netlist.Properties.VariableNames;
app.NetlistTable.ColumnEditable = ismember(cols, {'Sensitivity', 'IC', 'Expression', 'Derivative'});
app.WarningsTable.Data = r.Warnings;

s = r.Summary;
cls = s.Classification{1};
switch cls
    case 'LINEAR_CANDIDATE'
        color = [0 0.5 0];
    case 'NONLINEAR_COMPONENTS_PRESENT'
        color = [0.75 0 0];
    otherwise
        color = [0.8 0.45 0];
end
setResult(app, sprintf('Result: %s   (%d blocks, %d nets, %d electrical nodes, %d warnings)', ...
    cls, s.BlockCount, s.NetCount, s.ElectricalNodeCount, s.WarningCount), color);

% Every piece is forced into a column cell before stacking, so the
% vertical concatenations below always have matching widths.
msgs = {s.Explanation{1}; ''};
w = r.Warnings;
if height(w) > 0
    warnLines = cellfun(@(sev, code, msg) sprintf('[%s] %s: %s', sev, code, msg), ...
        w.Severity, w.Code, w.Message, 'UniformOutput', false);
    msgs = [msgs; {sprintf('Warnings (%d):', height(w))}; warnLines(:)];
else
    msgs = [msgs; {'No warnings.'}];
end
app.MessagesTextArea.Value = msgs;
end

function showError(app, ME, title)
% Print the full report (each stack frame with its source line) to the
% Command Window, save it to a file, and show it in the app.
txt = formatErrorReport(ME);
fprintf(2, '\n===== Circuit Inspector: %s =====\n%s\n\n', title, txt);
logFile = fullfile(tempdir, 'CircuitInspector_lastError.txt');
try
    fid = fopen(logFile, 'w');
    fprintf(fid, '%s\n', txt);
    fclose(fid);
catch
    logFile = '(could not be written)';
end
try
    app.MessagesTextArea.Value = [{[title ':']}; cellstr(splitlines(string(txt))); ...
        {''}; {['Saved to ' logFile]}];
    uialert(app.UIFigure, sprintf(['%s\n\nThe full report, with the file, function and line ' ...
        'of each failing statement, is in the Messages box and the Command Window.'], ...
        ME.message), title);
catch
    % The app itself may be gone; the Command Window copy is enough.
end
end

function setResult(app, text, color)
app.ClassificationLabel.Text = text;
app.ClassificationLabel.FontColor = color;
end

function clearTables(app)
app.ComponentsTable.Data = table();
app.PortsTable.Data = table();
app.NetsTable.Data = table();
app.NetlistTable.Data = table();
app.WarningsTable.Data = table();
end

% ---- Diagram tab ------------------------------------------------------

function ensureDiagramTab(app)
% Build the Diagram tab once, as the first tab of ResultsTabGroup.
if ~isempty(diagramUi(app, 'Tab'))
    return
end
tg = app.ResultsTabGroup;
tab = uitab(tg, 'Title', 'Diagram', 'Tag', 'CI_DiagramTab', 'AutoResizeChildren', 'off');
tg.Children = tg.Children([end, 1:end - 1]);     % move it to the front

g = uigridlayout(tab, [2 2]);
g.RowHeight = {'fit', '1x'};
g.ColumnWidth = {'1x', 'fit'};
g.Padding = [4 4 4 4];

info = uilabel(g, 'Tag', 'CI_DiagramInfo', 'WordWrap', 'on', 'Text', '');
info.Layout.Row = 1;
info.Layout.Column = 1;

btn = uibutton(g, 'push', 'Tag', 'CI_DiagramOpen', 'Text', 'Open in Simulink', ...
    'Enable', 'off', 'ButtonPushedFcn', @(~, ~) circuitInspectorActions('opendiagram', app));
btn.Layout.Row = 1;
btn.Layout.Column = 2;

img = uiimage(g, 'Tag', 'CI_DiagramImage', 'ScaleMethod', 'fit');
img.Layout.Row = 2;
img.Layout.Column = [1 2];
end

function h = diagramUi(app, part)
% part: 'Tab' | 'Info' | 'Open' | 'Image'
% Use the components designed in App Designer when the app has them;
% otherwise use the ones ensureDiagramTab created (found by Tag).
names = struct('Tab', 'DiagramTab', 'Info', 'DiagramInfoLabel', ...
    'Open', 'OpenInSimulinkButton', 'Image', 'DiagramImage');
prop = names.(part);
if isprop(app, prop) && ~isempty(app.(prop))
    h = app.(prop);
else
    h = findobj(app.UIFigure, 'Tag', ['CI_Diagram' part]);
end
end

function setUi(app, part, prop, value)
% MATLAB cannot assign to a property of a function's return value
% directly (f(x).Prop = v), so fetch the handle first.
h = diagramUi(app, part);
if ~isempty(h)
    set(h, prop, value);
end
end

function clearDiagram(app, text)
img = diagramUi(app, 'Image');
if isempty(img)
    return
end
img.ImageSource = '';
setUi(app, 'Info', 'Text', text);
setUi(app, 'Open', 'Enable', 'off');
end

function showDiagram(app)
ensureDiagramTab(app);
clearDiagram(app, 'Rendering diagram ...');
drawnow
try
    [png, info] = renderModelDiagram(app.ModelFile);
catch ME
    % A missing picture must not block inspection: report it and go on.
    clearDiagram(app, sprintf('No diagram available: %s', ME.message));
    setUi(app, 'Open', 'Enable', 'on');
    app.MessagesTextArea.Value = [app.MessagesTextArea.Value(:); ...
        {['Diagram: ' ME.message]}];
    return
end
setUi(app, 'Image', 'ImageSource', png);
txt = sprintf('%s   |   %s   |   saved %s', info.ModelName, info.File, info.FileDate);
if ~isempty(info.Note)
    txt = sprintf('%s\n%s', txt, info.Note);
    app.MessagesTextArea.Value = [app.MessagesTextArea.Value(:); {['Diagram: ' info.Note]}];
end
setUi(app, 'Info', 'Text', txt);
setUi(app, 'Open', 'Enable', 'on');
app.ResultsTabGroup.SelectedTab = diagramUi(app, 'Tab');
end

function openInSimulink(app)
if isempty(app.ModelFile)
    return
end
open_system(app.ModelFile);
end

function closeDialog(d)
if isvalid(d)
    close(d);
end
end
