%*****DO NOT RUN THIS, it is not finished and likely won't be*******&
function mlappFile = buildCircuitInspectorMlapp(outFolder)


%BUILDCIRCUITINSPECTORMLAPP  Write gui/CircuitInspectorApp.mlapp directly.
%
%   mlappFile = buildCircuitInspectorMlapp()
%   mlappFile = buildCircuitInspectorMlapp(outFolder)
%
%   Alternative to the plain-text route (app_source/*.m + *.xml, R2026b+).
%   Use this on R2025a or R2025b, where App Designer cannot open
%   plain-text apps.
%
%   Requires MathWorks' MATLAB Agentic Toolkit, which provides
%   AppDesignerAgentInterface (https://github.com/matlab/matlab-agentic-toolkit).
%   Put its folder on the path first, for example:
%     addpath('<toolkit>/skills-catalog/matlab-app-building/matlab-build-app/scripts')
%   MathWorks describes AppDesignerAgentInterface as an internal API that
%   can change between releases; if a call below errors, use the manual
%   Design View steps in README.md instead.
%
%   The layout and callbacks are the same as app_source/CircuitInspectorApp.xml.

if nargin < 1 || isempty(outFolder)
    outFolder = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'gui');
end
if exist('AppDesignerAgentInterface', 'class') ~= 8
    error('buildCircuitInspectorMlapp:noToolkit', ['AppDesignerAgentInterface was not found. ' ...
        'Add matlab-agentic-toolkit/skills-catalog/matlab-app-building/matlab-build-app/scripts ' ...
        'to the path, or use the plain-text route / manual steps in README.md.']);
end
mlappFile = fullfile(outFolder, 'CircuitInspectorApp.mlapp');
if isfile(mlappFile)
    error('buildCircuitInspectorMlapp:exists', ...
        '%s already exists. Delete or rename it first.', mlappFile);
end

b = AppDesignerAgentInterface.create(mlappFile);

% ---- figure and main grid ----
b.setProperty("UIFigure", "Name", "Circuit Inspector");
b.setProperty("UIFigure", "Position", [100 100 1150 720]);
b.setProperty("UIFigure", "AutoResizeChildren", "off");
b.addComponent("GridLayout", "MainGrid", "UIFigure", struct( ...
    'ColumnWidth', {{'1x'}}, 'RowHeight', {{'fit', 'fit', '1x', 150}}, ...
    'Padding', [10 10 10 10], 'RowSpacing', 8));

% ---- toolbar row ----
b.addComponent("GridLayout", "ToolbarGrid", "MainGrid", struct( ...
    'ColumnWidth', {{'fit', 'fit', 'fit', '1x'}}, 'RowHeight', {{'fit'}}, ...
    'Padding', [0 0 0 0], 'ColumnSpacing', 8, 'Layout', struct('Row', 1, 'Column', 1)));
b.addComponent("Button", "SelectModelButton", "ToolbarGrid", struct( ...
    'Text', '1. Select Model', 'Layout', struct('Row', 1, 'Column', 1)));
b.addComponent("Button", "InspectButton", "ToolbarGrid", struct( ...
    'Text', '2. Inspect', 'Enable', 'off', 'Layout', struct('Row', 1, 'Column', 2)));
b.addComponent("Button", "ExportButton", "ToolbarGrid", struct( ...
    'Text', '3. Export CSVs', 'Enable', 'off', 'Layout', struct('Row', 1, 'Column', 3)));
b.addComponent("Label", "ModelPathLabel", "ToolbarGrid", struct( ...
    'Text', 'No model selected.', 'Layout', struct('Row', 1, 'Column', 4)));

% ---- result line ----
b.addComponent("Label", "ClassificationLabel", "MainGrid", struct( ...
    'Text', 'Result: not inspected yet', 'FontSize', 14, 'FontWeight', 'bold', ...
    'Layout', struct('Row', 2, 'Column', 1)));

% ---- tabs, one table each ----
b.addComponent("TabGroup", "ResultsTabGroup", "MainGrid", struct( ...
    'Layout', struct('Row', 3, 'Column', 1)));
tabs = ["Components", "Ports", "Nets", "Netlist", "Warnings"];
for t = tabs
    b.addComponent("Tab", t + "Tab", "ResultsTabGroup", struct('Title', char(t)));
    b.addComponent("GridLayout", t + "Grid", t + "Tab", struct( ...
        'ColumnWidth', {{'1x'}}, 'RowHeight', {{'1x'}}, 'Padding', [4 4 4 4]));
    b.addComponent("Table", t + "Table", t + "Grid", struct( ...
        'Layout', struct('Row', 1, 'Column', 1)));
end

% ---- messages ----
b.addComponent("TextArea", "MessagesTextArea", "MainGrid", struct( ...
    'Editable', 'off', 'Layout', struct('Row', 4, 'Column', 1)));

% ---- app data and callbacks (all behavior lives in gui/circuitInspectorActions.m) ----
b.addProperty("ModelFile", "", "public");
b.addProperty("Report", "", "public");
b.addCallback("SelectModelButton", "ButtonPushedFcn", "SelectModelButtonPushed");
b.setCallbackCode("SelectModelButtonPushed", "circuitInspectorActions('select', app);");
b.addCallback("InspectButton", "ButtonPushedFcn", "InspectButtonPushed");
b.setCallbackCode("InspectButtonPushed", "circuitInspectorActions('inspect', app);");
b.addCallback("ExportButton", "ButtonPushedFcn", "ExportButtonPushed");
b.setCallbackCode("ExportButtonPushed", "circuitInspectorActions('export', app);");
b.addCallback("UIFigure", "StartupFcn", "startupFcn");
b.setCallbackCode("startupFcn", "circuitInspectorActions('startup', app);");

problems = b.validate();
if ~isempty(problems)
    error('buildCircuitInspectorMlapp:invalid', 'App validation failed: %s', ...
        strjoin(string({problems.message}), ' | '));
end
b.save();

% Opens the app in App Designer and saves it through App Designer, which
% generates the full runnable class code inside the .mlapp.
AppDesignerAgentInterface.finalize(mlappFile, 120);
fprintf('Created %s\n', mlappFile);
end
