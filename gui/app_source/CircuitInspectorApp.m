classdef CircuitInspectorApp < matlab.apps.App

    % Used to locate and load the app's XML configuration file
    properties (Access = public, Constant)
        AppConfigFilename = './CircuitInspectorApp.xml'; % File path to the app configuration file containing component layout and settings
    end

    % Properties that correspond to app components
    properties (Access = public)
        UIFigure                        matlab.ui.Figure
        MainGrid                        matlab.ui.container.GridLayout
        MessagesTextArea                matlab.ui.control.TextArea
        ResultsTabGroup                 matlab.ui.container.TabGroup
        ComponentsTab                   matlab.ui.container.Tab
        ComponentsGrid                  matlab.ui.container.GridLayout
        ComponentsTable                 matlab.ui.control.Table
        PortsTab                        matlab.ui.container.Tab
        PortsGrid                       matlab.ui.container.GridLayout
        PortsTable                      matlab.ui.control.Table
        NetsTab                         matlab.ui.container.Tab
        NetsGrid                        matlab.ui.container.GridLayout
        NetsTable                       matlab.ui.control.Table
        NetlistTab                      matlab.ui.container.Tab
        NetlistGrid                     matlab.ui.container.GridLayout
        NetlistTable                    matlab.ui.control.Table
        WarningsTab                     matlab.ui.container.Tab
        WarningsGrid                    matlab.ui.container.GridLayout
        WarningsTable                   matlab.ui.control.Table
        ClassificationLabel             matlab.ui.control.Label
        ToolbarGrid                     matlab.ui.container.GridLayout
        ModelPathLabel                  matlab.ui.control.Label
        ExportButton                    matlab.ui.control.Button
        InspectButton                   matlab.ui.control.Button
        SelectModelButton               matlab.ui.control.Button
    end

    % App data, read and written by circuitInspectorActions.m
    properties (Access = public)
        ModelFile = ''      % full path of the selected .slx/.mdl file
        Report = []         % struct returned by inspectCircuit
    end

    % Callbacks that handle component events
    methods

        % Code that executes after component creation
        function startupFcn(app)
            circuitInspectorActions('startup', app);
        end

        % Button pushed function: SelectModelButton
        function SelectModelButtonPushed(app, event)
            circuitInspectorActions('select', app);
        end

        % Button pushed function: InspectButton
        function InspectButtonPushed(app, event)
            circuitInspectorActions('inspect', app);
        end

        % Button pushed function: ExportButton
        function ExportButtonPushed(app, event)
            circuitInspectorActions('export', app);
        end
    end

    % App creation
    methods (Access = public)

        % Construct app
        function app = CircuitInspectorApp(varargin)
            app = app@matlab.apps.App(varargin{:});

            if nargout == 0
                clear app
            end
        end
    end
end