function [modelName, modelFile] = buildInspectorDemo(variant, folder)
%BUILDINSPECTORDEMO  Build small Simscape test circuits for inspectCircuit.
%
%   [modelName, modelFile] = buildInspectorDemo(variant)
%   [modelName, modelFile] = buildInspectorDemo(variant, folder)
%
%   variant (default 'linear'):
%     'linear'     Foundation library: DC source -> R -> C -> ground.
%                  Expected: LINEAR_CANDIDATE, nodes n1, n2, 0.
%     'linear_ee'  Same circuit built from Simscape Electrical (ee_lib)
%                  blocks, with TWO Electrical Reference blocks, like a
%                  typical hand-built model. Expected: LINEAR_CANDIDATE; both
%                  references are node 0.
%     'no_solver'  'linear_ee' without a Solver Configuration block.
%                  Expected: NO_SOLVER_CONFIGURATION error in Warnings.
%     'nonlinear'  'linear' with the capacitor replaced by a diode.
%                  Expected: NONLINEAR_COMPONENTS_PRESENT.
%     'subsystem'  R and C inside a user subsystem with Connection Ports.
%                  Expected: the source's + terminal and R's + terminal on
%                  the same node across the subsystem boundary.
%     'branched'   One source driving two parallel resistors with branched
%                  wires. Expected: one net carrying three terminals.
%
%   The model is saved as <folder>/inspector_demo_<variant>.slx
%   (folder defaults to tempdir) and left open. Any previously built copy
%   with the same name is closed without saving and overwritten.

if nargin < 1 || isempty(variant)
    variant = 'linear';
end
if nargin < 2 || isempty(folder)
    folder = tempdir;
end
variant = lower(char(variant));
valid = {'linear', 'linear_ee', 'no_solver', 'nonlinear', 'subsystem', 'branched'};
if ~any(strcmp(variant, valid))
    error('buildInspectorDemo:badVariant', 'Unknown variant "%s". Valid: %s.', ...
        variant, strjoin(valid, ', '));
end

useEE = any(strcmp(variant, {'linear_ee', 'no_solver'}));
FL = 'fl_lib/Electrical/Electrical Elements/';
SRC = 'fl_lib/Electrical/Electrical Sources/';
load_system('fl_lib');
load_system('nesl_utility');
if useEE
    if exist('ee_lib', 'file') ~= 4
        error('buildInspectorDemo:noSimscapeElectrical', ...
            'Variant "%s" needs Simscape Electrical (ee_lib), which is not installed.', variant);
    end
    load_system('ee_lib');
end

modelName = ['inspector_demo_' variant];
modelFile = fullfile(folder, [modelName '.slx']);
if bdIsLoaded(modelName)
    close_system(modelName, 0);
end
if isfile(modelFile)
    delete(modelFile);
end
new_system(modelName);
m = modelName;

switch variant
    case {'linear', 'nonlinear'}
        vs  = addB(m, [SRC 'DC Voltage Source'], 'Vs', [60 140 100 180]);
        r   = addB(m, [FL 'Resistor'], 'R', [160 60 200 100]);
        if strcmp(variant, 'linear')
            x = addB(m, [FL 'Capacitor'], 'C', [260 140 300 180]);
        else
            x = addB(m, [FL 'Diode'], 'D', [260 140 300 180]);
        end
        gnd = addB(m, [FL 'Electrical Reference'], 'Ground', [170 260 190 280]);
        sc  = addB(m, 'nesl_utility/Solver Configuration', 'Solver', [40 240 80 270]);
        wire(m, vs, 'LConn', 1, r, 'LConn', 1);
        wire(m, r, 'RConn', 1, x, 'LConn', 1);
        wire(m, x, 'RConn', 1, gnd, 'LConn', 1);
        wire(m, vs, 'RConn', 1, gnd, 'LConn', 1);
        wire(m, sc, 'RConn', 1, gnd, 'LConn', 1);

    case {'linear_ee', 'no_solver'}
        vs   = addB(m, 'ee_lib/Sources/Voltage Source', 'Voltage Source', [60 140 100 180]);
        r    = addB(m, 'ee_lib/Passive/Resistor', 'Resistor', [160 60 200 100]);
        c    = addB(m, 'ee_lib/Passive/Capacitor', 'Capacitor', [260 140 300 180]);
        gndA = addB(m, [FL 'Electrical Reference'], 'Electrical Reference', [270 240 290 260]);
        gndB = addB(m, [FL 'Electrical Reference'], 'Electrical Reference1', [70 240 90 260]);
        wire(m, vs, 'LConn', 1, r, 'LConn', 1);
        wire(m, r, 'RConn', 1, c, 'LConn', 1);
        wire(m, c, 'RConn', 1, gndA, 'LConn', 1);
        wire(m, vs, 'RConn', 1, gndB, 'LConn', 1);
        if strcmp(variant, 'linear_ee')
            sc = addB(m, 'nesl_utility/Solver Configuration', 'Solver', [140 240 180 270]);
            wire(m, sc, 'RConn', 1, gndB, 'LConn', 1);
        end

    case 'subsystem'
        vs  = addB(m, [SRC 'DC Voltage Source'], 'Vs', [60 140 100 180]);
        gnd = addB(m, [FL 'Electrical Reference'], 'Ground', [170 260 190 280]);
        sc  = addB(m, 'nesl_utility/Solver Configuration', 'Solver', [40 240 80 270]);
        sub = [m '/RC Filter'];
        add_block('built-in/Subsystem', sub, 'Position', [180 120 260 200]);
        a = addB(sub, 'nesl_utility/Connection Port', 'In', [40 100 70 120]);
        b = addB(sub, 'nesl_utility/Connection Port', 'Out', [400 100 430 120]);
        set_param(a, 'Side', 'Left');
        set_param(b, 'Side', 'Right');
        r = addB(sub, [FL 'Resistor'], 'R', [140 90 180 130]);
        c = addB(sub, [FL 'Capacitor'], 'C', [260 90 300 130]);
        wire(sub, a, 'RConn', 1, r, 'LConn', 1);
        wire(sub, r, 'RConn', 1, c, 'LConn', 1);
        wire(sub, c, 'RConn', 1, b, 'RConn', 1);
        subH = get_param(sub, 'Handle');
        wire(m, vs, 'LConn', 1, subH, 'LConn', 1);
        wire(m, subH, 'RConn', 1, gnd, 'LConn', 1);
        wire(m, vs, 'RConn', 1, gnd, 'LConn', 1);
        wire(m, sc, 'RConn', 1, gnd, 'LConn', 1);

    case 'branched'
        vs  = addB(m, [SRC 'DC Voltage Source'], 'Vs', [60 140 100 180]);
        r1  = addB(m, [FL 'Resistor'], 'R1', [200 60 240 100]);
        r2  = addB(m, [FL 'Resistor'], 'R2', [200 180 240 220]);
        gnd = addB(m, [FL 'Electrical Reference'], 'Ground', [330 260 350 280]);
        sc  = addB(m, 'nesl_utility/Solver Configuration', 'Solver', [40 240 80 270]);
        wire(m, vs, 'LConn', 1, r1, 'LConn', 1);
        wire(m, vs, 'LConn', 1, r2, 'LConn', 1);      % second wire on the same port -> branch
        wire(m, r1, 'RConn', 1, gnd, 'LConn', 1);
        wire(m, r2, 'RConn', 1, gnd, 'LConn', 1);
        wire(m, vs, 'RConn', 1, gnd, 'LConn', 1);
        wire(m, sc, 'RConn', 1, gnd, 'LConn', 1);
end

save_system(m, modelFile);
end

% ---------------------------------------------------------------------

function h = addB(sys, libPath, name, pos)
try
    h = add_block(libPath, [sys '/' name], 'Position', pos);
catch ME
    err = MException('buildInspectorDemo:addBlockFailed', ...
        'Could not add "%s" from "%s". Check this library path in your release.', name, libPath);
    throw(addCause(err, ME));
end
end

function wire(sys, a, aGroup, aIdx, b, bGroup, bIdx)
pa = portOf(a, aGroup, aIdx);
pb = portOf(b, bGroup, bIdx);
try
    add_line(sys, pa, pb, 'autorouting', 'on');
catch ME
    err = MException('buildInspectorDemo:addLineFailed', 'Could not wire %s.%s%d to %s.%s%d.', ...
        get_param(a, 'Name'), aGroup, aIdx, get_param(b, 'Name'), bGroup, bIdx);
    throw(addCause(err, ME));
end
end

function p = portOf(h, group, idx)
ph = get_param(h, 'PortHandles');
ports = ph.(group);
if numel(ports) >= idx
    p = ports(idx);
    return
end
% Single-port blocks (Electrical Reference, Solver Configuration, Connection
% Port) put their one port on a side that can differ between releases and
% settings, so use whichever physical port the block has.
phys = [ph.LConn(:); ph.RConn(:)];
if idx == 1 && numel(phys) == 1
    p = phys;
    return
end
error('buildInspectorDemo:noSuchPort', '%s has no %s%d port (it has %d LConn and %d RConn ports).', ...
    get_param(h, 'Name'), group, idx, numel(ph.LConn), numel(ph.RConn));
end
