# solver_core

MATLAB transient + sensitivity solver for circuits written in MNA form:

    C dx/dt + G x + F(x) = B(t)

`runSolver` returns the nominal response x(t) and the sensitivity M(t) = dx/dp, plus plots of both.
The full description of every input is in `functionReadMe.mlx` (open in MATLAB). Worked examples for all four paths are in `testRun.mlx`.

## Files

| File | Purpose |
|---|---|
| `runSolver.m` | Entry point. Picks the solve path, computes x(t) and M(t), makes plots |
| `assemble.m` | Turns the cell-array inputs (B, F, dFdx, dCxdp, dGxdp) into vectors/matrices at a given x or t |
| `newtonIterate.m` | Newton-Raphson for one timestep (paths 1 and 3) |
| `numaricalDerivitive.m` | Central-difference dx/dt (no longer used by runSolver) |
| `docs/notes/` | Hand-written derivations and the test circuits |

## Usage

```matlab
[xNomPlot, MPlot, x, M, t] = runSolver(C, dCxdp, G, dGxdp, F, dFdx, B, lnth, h, time, path)
```

| path | Circuit | Method | Ignored inputs |
|---|---|---|---|
| 0 | linear, no C/L | `G \ B(t)` each step | C, dCxdp, F, dFdx |
| 1 | nonlinear, no C/L | Newton each step | C, dCxdp |
| 2 | C/L, linear | Backward Euler | F, dFdx |
| 3 | C/L and nonlinear | Backward Euler + Newton | none |

## Input format (summary)

- `C`, `G`: ordinary x-by-x MNA stamp matrices (inductors enter C as 1/L).
- `B`: one row per independent source: `{stampVector, value or @(t), isTimeVarying}`.
- `F`: one row per nonlinear element: `{stampVector, @(vH,vL) I, [nodeH, nodeL]}` (use 0 for ground).
- `dFdx`: same rows as F: `{stampMatrix, @(vH,vL) dI/dv, [nodeH, nodeL]}`.
- `dGxdp`, `dCxdp`: one row per parameter p: `{stampVector, [nodeH, nodeL]}`. Use a zero stamp with `[0,0]` if the parameter isn't in that matrix.
- `lnth = [length of x, length of p]`, `h` = timestep, `time` = simulation length.

## Outputs

- `x`: length(x)-by-timesteps. `x(:,n)` is the solution at `t(n)`.
- `M`: 1-by-length(p) cell array. `M{m}(:,n)` is dx/dp_m at `t(n)`.

## Known limitations / TODO

- No input validation yet.
- The initial guess / initial condition is always zero.
- Newton stops with an error if it hasn't converged after 20 iterations.
