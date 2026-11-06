function results = runInspectorSmokeTests(keepModels)
%RUNINSPECTORSMOKETESTS  Build each demo circuit, inspect it, check the result.
%
%   results = runInspectorSmokeTests()
%   results = runInspectorSmokeTests(true)   % leave the demo models open
%
%   Prints PASS / FAIL / SKIP per case and returns a table. On failure, the
%   full error report (file, function, line and source text of every frame)
%   is printed, so you can see exactly which statement failed.

if nargin < 1
    keepModels = false;
end
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..', 'gui'));
outRoot = fullfile(tempdir, 'circuit_inspector_tests');

% variant, expected classification, extra check, needs ee_lib
cases = {
    'linear',    'LINEAR_CANDIDATE',             @checkLinear,    false
    'linear_ee', 'LINEAR_CANDIDATE',             @checkLinearEE,  true
    'no_solver', '',                             @checkNoSolver,  true
    'nonlinear', 'NONLINEAR_COMPONENTS_PRESENT', @checkNothing,   false
    'subsystem', 'LINEAR_CANDIDATE',             @checkSubsystem, false
    'branched',  'LINEAR_CANDIDATE',             @checkBranched,  false
    };
hasEE = exist('ee_lib', 'file') == 4;

n = size(cases, 1);
status = cell(n, 1);
detail = cell(n, 1);
for k = 1:n
    variant = cases{k, 1};
    if cases{k, 4} && ~hasEE
        status{k} = 'SKIP';
        detail{k} = 'Simscape Electrical (ee_lib) is not installed.';
        fprintf('SKIP  %-10s %s\n', variant, detail{k});
        continue
    end
    try
        [name, file] = buildInspectorDemo(variant);
        report = inspectCircuit(file, fullfile(outRoot, variant));
        got = report.Summary.Classification{1};
        if ~isempty(cases{k, 2}) && ~strcmp(got, cases{k, 2})
            error('smoke:classification', 'Expected %s, got %s. Explanation: %s%s', ...
                cases{k, 2}, got, report.Summary.Explanation{1}, flaggedReasons(report));
        end
        cases{k, 3}(report);
        status{k} = 'PASS';
        detail{k} = got;
        fprintf('PASS  %-10s %s\n', variant, got);
        if ~keepModels
            close_system(name, 0);
        end
    catch ME
        status{k} = 'FAIL';
        detail{k} = ME.message;
        fprintf(2, 'FAIL  %-10s\n%s\n\n', variant, formatErrorReport(ME));
    end
end
results = table(cases(:, 1), status, detail, 'VariableNames', {'Variant', 'Status', 'Detail'});
fprintf('\nCSV output for each case is under %s\n', outRoot);
end

% ---------------------------------------------------------------------

function checkNothing(~)
end

function txt = flaggedReasons(r)
% Reason text for every circuit component that is not plainly LINEAR,
% plus the raw parameter values of those components.
c = r.Components;
bad = find(ismember(c.Assessment, {'UNKNOWN', 'NONLINEAR'}));
txt = '';
for i = bad(:)'
    txt = sprintf('%s\n  %s (%s): %s', txt, c.Designator{i}, c.Assessment{i}, c.Reason{i});
    p = r.Parameters(strcmp(r.Parameters.ComponentID, c.ComponentID{i}), :);
    for j = 1:height(p)
        txt = sprintf('%s\n      %s | %s = %s', txt, p.Parameter{j}, p.Prompt{j}, p.Value{j});
    end
end
end

function checkLinear(r)
% Node names (n1, n2, ...) depend on block order, so compare which
% terminals share a node instead of exact names.
nl = r.Netlist;
expectEqual(height(nl), 3, 'netlist rows (V, R, C)');
expectSame(nl, 'V1+', 'R1+');
expectSame(nl, 'R1-', 'C1+');
expectGround(nl, 'C1-');
expectGround(nl, 'V1-');
expectDifferent(nl, 'R1+', 'R1-');
end

function checkLinearEE(r)
checkLinear(r);
refs = strcmp(r.Components.Role, 'REFERENCE');
expectEqual(nnz(refs), 2, 'Electrical Reference blocks');
refPorts = ismember(r.Ports.ComponentID, r.Components.ComponentID(refs));
expectTrue(all(strcmp(r.Ports.NodeID(refPorts), '0')), 'both references are node 0');
end

function checkNoSolver(r)
expectTrue(any(strcmp(r.Warnings.Code, 'NO_SOLVER_CONFIGURATION')), ...
    'a NO_SOLVER_CONFIGURATION warning');
end

function checkSubsystem(r)
% R and C are inside the subsystem; V is outside.
nl = r.Netlist;
expectSame(nl, 'V1+', 'R1+');
expectSame(nl, 'R1-', 'C1+');
expectGround(nl, 'C1-');
expectGround(nl, 'V1-');
expectDifferent(nl, 'R1+', 'R1-');
end

function checkBranched(r)
expectTrue(any(r.Nets.ComponentPortCount == 3), 'one net with three terminals (V+, R1+, R2+)');
nl = r.Netlist;
expectSame(nl, 'V1+', 'R1+');
expectSame(nl, 'V1+', 'R2+');
expectGround(nl, 'R1-');
expectGround(nl, 'R2-');
end

function node = nodeOf(nl, terminal)
% terminal is a designator plus '+' or '-', e.g. 'R1+'.
designator = terminal(1:end - 1);
row = strcmp(nl.Designator, designator);
expectTrue(nnz(row) == 1, sprintf('exactly one netlist row for %s', designator));
if terminal(end) == '+'
    node = nl.PositiveNode{row};
else
    node = nl.NegativeNode{row};
end
expectTrue(~strcmp(node, '?'), sprintf('%s to be connected', terminal));
end

function expectSame(nl, a, b)
na = nodeOf(nl, a);
nb = nodeOf(nl, b);
if ~strcmp(na, nb)
    error('smoke:nodes', 'Expected %s and %s on the same node, got %s and %s.', a, b, na, nb);
end
end

function expectDifferent(nl, a, b)
na = nodeOf(nl, a);
nb = nodeOf(nl, b);
if strcmp(na, nb)
    error('smoke:nodes', 'Expected %s and %s on different nodes, both are %s.', a, b, na);
end
end

function expectGround(nl, a)
na = nodeOf(nl, a);
if ~strcmp(na, '0')
    error('smoke:nodes', 'Expected %s on ground (node 0), got %s.', a, na);
end
end

function expectEqual(got, want, what)
if ~isequal(got, want)
    error('smoke:value', 'Expected %s = %s, got %s.', what, mat2str(want), mat2str(got));
end
end

function expectTrue(cond, what)
if ~cond
    error('smoke:check', 'Expected %s.', what);
end
end
