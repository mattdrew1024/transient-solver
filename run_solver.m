function out = run_solver(model, opts)
%RUN_SOLVER  Main entry point: Simscape model -> transient + sensitivity results.
%
%   out = run_solver(model)
%   out = run_solver(model, Params={'R1','C1'}, h=1e-6, Time=5e-3)
%
%   Runs the whole chain:
%     1. inspectCircuit      (gui/)        read the model, build the netlist
%     2. solver.build_mna    (+solver/)    netlist -> C, G, B, F, ... stamps
%     3. runSolver           (+solver/solver_LashaVersion/, prototype)
%                                          x(t) and M(t) = dx/dp
%     4. save                (results/)    .mat file + inspection CSVs
%
%   model   Model name on the path (e.g. 'test_linear_RC') or a path to a .slx.
%
%   Name-value options:
%     Params        cell array of element designators to take sensitivities
%                   with respect to, e.g. {'R1','C1'}. Default {} (none).
%     h             timestep in seconds. Default 1e-6.
%     Time          simulation length in seconds. Default 5e-3.
%     Plot          show runSolver's figures. Default true.
%     Save          write results to results/<model>_<timestamp>/. Default true.
%     AllowUnknown  continue when the inspector can't classify every block.
%                   Default false.
%
%   out is a struct with fields
%     x, M, t       as returned by runSolver (see solver_core/README.md)
%     names         label for each row of x, e.g. 'v(n1)', 'i(V1)'
%     path          solve path used (0-3, see solver_core/README.md)
%     report        the inspectCircuit report
%     mna           the struct returned by solver.build_mna
%     folder        where results were saved ('' if Save=false)
%
%   CONTRACT FOR solver.build_mna (to be implemented):
%     mna = solver.build_mna(netlist, params)
%       netlist  report.Netlist table from inspectCircuit
%       params   cell array of designators, same as opts.Params
%     mna must have fields:
%       C, G          x-by-x MNA matrices
%       B, F, dFdx    cell arrays in the format in solver_core/README.md
%       dCxdp, dGxdp  one row per entry of params
%       lnth          [length(x), length(params)]
%       names         1-by-length(x) cellstr of row labels

arguments
    model {mustBeTextScalar}
    opts.Params cell = {}
    opts.h (1,1) double {mustBePositive} = 1e-6
    opts.Time (1,1) double {mustBePositive} = 5e-3
    opts.Plot (1,1) logical = true
    opts.Save (1,1) logical = true
    opts.AllowUnknown (1,1) logical = false
end
model = char(model);

% ---------------------------------------------------------------- 1. inspect
fprintf('[run_solver] Inspecting %s ...\n', model);
report = inspectCircuit(model);
classification = string(report.Summary.Classification(1));
explanation    = string(report.Summary.Explanation(1));
fprintf('[run_solver]   %s: %s\n', classification, explanation);

if classification == "UNKNOWN" && ~opts.AllowUnknown
    error('run_solver:unknownCircuit', ...
        ['The inspector could not classify every block:\n  %s\n' ...
         'Fix the model, or pass AllowUnknown=true to continue anyway.'], explanation);
end

% ---------------------------------------------------------------- 2. build MNA
fprintf('[run_solver] Building MNA matrices ...\n');
try
    mna = solver.build_mna(report.Netlist, opts.Params);
catch ME
    if any(strcmp(ME.identifier, {'MATLAB:scriptNotAFunction', 'MATLAB:TooManyInputs', ...
            'MATLAB:maxlhs', 'MATLAB:UndefinedFunction'}))
        error('run_solver:buildMnaNotImplemented', ...
            ['solver.build_mna is not implemented yet (+solver/build_mna.m).\n' ...
             'It must be a function  mna = build_mna(netlist, params).\n' ...
             'See the CONTRACT section in "help run_solver" for the fields it must return.']);
    end
    rethrow(ME);
end
checkMna(mna, numel(opts.Params));

% ---------------------------------------------------------------- 3. solve
hasC = any(mna.C(:) ~= 0);
hasF = ~isempty(mna.F);
solvePath = 2*hasC + hasF;   % 0..3, matches the table in solver_core/README.md
fprintf('[run_solver] Solving (path %d, h = %g s, T = %g s) ...\n', solvePath, opts.h, opts.Time);

[xNomPlot, MPlot, x, M, t] = runSolver(mna.C, mna.dCxdp, mna.G, mna.dGxdp, ...
    mna.F, mna.dFdx, mna.B, mna.lnth, opts.h, opts.Time, solvePath);
if ~opts.Plot
    close(xNomPlot);
    for k = 1:numel(MPlot)
        close(MPlot(k));
    end
end

% ---------------------------------------------------------------- 4. save
folder = '';
if opts.Save
    [~, modelName] = fileparts(model);
    root   = fileparts(mfilename('fullpath'));
    folder = fullfile(root, 'results', ...
        sprintf('%s_%s', modelName, char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'))));
    writeInspectionReport(report, folder);
    names = mna.names; params = opts.Params; h = opts.h; T = opts.Time; %#ok<NASGU>
    save(fullfile(folder, 'solution.mat'), 'x', 'M', 't', 'names', 'params', ...
        'solvePath', 'h', 'T', 'mna');
    fprintf('[run_solver] Saved to %s\n', folder);
end

out = struct('x', x, 'M', {M}, 't', t, 'names', {mna.names}, 'path', solvePath, ...
    'report', report, 'mna', mna, 'folder', folder);
end


function checkMna(mna, nParams)
%CHECKMNA  Catch contract mistakes in build_mna's output before runSolver does.
required = {'C', 'G', 'B', 'F', 'dFdx', 'dCxdp', 'dGxdp', 'lnth', 'names'};
missing = required(~isfield(mna, required));
if ~isempty(missing)
    error('run_solver:badMna', 'build_mna output is missing field(s): %s', ...
        strjoin(missing, ', '));
end
n = mna.lnth(1);
if ~isequal(size(mna.G), [n n]) || ~isequal(size(mna.C), [n n])
    error('run_solver:badMna', 'C and G must be %d-by-%d (lnth(1) = %d).', n, n, n);
end
if mna.lnth(2) ~= nParams || size(mna.dGxdp, 1) ~= nParams || size(mna.dCxdp, 1) ~= nParams
    error('run_solver:badMna', ...
        'Expected %d parameter row(s) in dGxdp/dCxdp and lnth(2) = %d.', nParams, nParams);
end
if numel(mna.names) ~= n
    error('run_solver:badMna', 'names must have one label per row of x (%d).', n);
end
end
