# Circuit Inspector (MATLAB R2026b)

Turns a Simscape circuit model into the single circuit CSV that the transient solver reads, and tells you whether the circuit is linear.

## Workflow

1. **Run CircuitInspectorApp.m**
2. **Select Model.** Pick your `.slx` file. The Diagram tab shows the preview Simulink saved in the file, along with its path and save date, so you can check it's the right model. Click "Open in Simulink" to open the model itself.
3. **Inspect.** The app reads the model without simulating or changing it. The bold result line says one of the following:
   - `LINEAR_CANDIDATE`: no nonlinear parts were found.
   - `NONLINEAR_COMPONENTS_PRESENT`: see the Components tab for which parts.
   - `UNKNOWN`: a block has no rule yet, or there's a feedback path the app can't analyze.
4. **Review the tabs.**
   - **Netlist:** the circuit CSV, one row per part. You can type into the Sensitivity, IC, Expression and Derivative columns.
   - **Warnings:** read these first. `ERROR` rows, such as a missing Solver Configuration, mean the model won't simulate.
   - **Components, Ports, Nets:** show how the CSV was derived. Use them to track down a wrong node.
5. **Export CSV.** Saves the Netlist tab, including your edits, as one file, for example `test_circuits/<model>.csv`.

If something fails, the Messages box and the Command Window show every file, function and line involved. The same report is saved to `tempdir/CircuitInspector_lastError.txt`.

## Circuit CSV

```
Designator,Type,NodePos,NodeNeg,Value,Waveform,Amplitude,Frequency,Phase,IC,Sensitivity,Expression,Derivative
```

How each column is filled from the model:

| Column | Filled from |
|---|---|
| Designator | R1, C1, L1, V1, I1, D1, ..., numbered in block order |
| Type | Resistor `R`, Capacitor `C`, Inductor `L`, voltage source `V`, current source `I`, and `NL` for nonlinear two-terminal parts (diode, thermal-port variants) |
| NodePos / NodeNeg | The block's `+` / `-` terminal. Every Electrical Reference is node `0`; other nodes are `n1`, `n2`, ... |
| Value | R, C, L or the source's DC level, converted to SI units (Ohm, F, H, V, A). Workspace variables are resolved. |
| Waveform, Amplitude, Frequency, Phase | `SIN` when the source's AC amplitude isn't 0, otherwise `DC`. Phase is in rad. |
| IC | The capacitor voltage or inductor current, only when its initial target is enabled in the block. Otherwise blank (= 0). |
| Sensitivity, Expression, Derivative | Not in the model; fill them in on the Netlist tab |

Notes:
- **Current sources:** Simscape Electrical's Current Source pushes current through the source from - to +. That matches the CSV rule (injected into NodePos), so NodePos is the block's `+`.
- **Current sensors:** each is exported as a 0 V source named `V<designator>`, which keeps the short circuit and gives the solver the sensor current.
- **Not exported:** voltage sensors, solver and ground blocks. Parts with more than two terminals, and signal-controlled parts, are also skipped, with a `NOT_IN_CSV` warning.
- **Export is blocked** if two parts share a designator or a terminal is unconnected (node `?`).
- **Not generated:** `IC` rows (starting node voltages) aren't generated. Add them to the CSV by hand if you need them.

## Command line and tests

```matlab
r = inspectCircuit('test_linear_RC.slx', 'test_circuits');   % writes test_circuits/test_linear_RC.csv
r.Netlist, r.Warnings
runInspectorSmokeTests                                        % builds demo circuits, prints PASS/FAIL
```

## Files

| File | Purpose |
|---|---|
| `gui/app_source/CircuitInspectorApp.m`, `.xml` | the app (layout and one-line callbacks) |
| `gui/circuitInspectorActions.m` | everything the buttons do |
| `gui/inspectCircuit.m` | reads the model: parts, wiring, linearity, circuit CSV rows |
| `gui/writeCircuitCsv.m` | checks and writes the circuit CSV |
| `gui/renderModelDiagram.m` | gets the stored model preview for the Diagram tab |
| `gui/formatErrorReport.m` | error report with file, function and line |
| `gui/buildInspectorDemo.m`, `tests/runInspectorSmokeTests.m` | demo models and tests |
