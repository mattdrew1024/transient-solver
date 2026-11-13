function xConverged = newtonIterate(xStart, G, V, F, dFdx, C, h, lnth)

maxLoops = 20;
acceptableConvergence = 0.00001;


xCurrent = xStart;
 

for i = 0:maxLoops
    % sub xCurrent into f
    f = (G + C/h)*xCurrent + assemble(F,xCurrent,0,lnth,"F") - V;

    % check if f(xCurrent) converges to 0
    if (abs(f)<acceptableConvergence)
        xConverged = xCurrent;
        break
    end
    % check for non convergence HANDLE THIS!!!!!!!
    if (i == maxLoops)
        error("Does not converge")
    end

    % sub xCurrent into dfdx
    dfdx = G + C/h + assemble(dFdx,xCurrent,0,lnth,"dF");

    % calculate the new xCurrent using dfdx*delX =-f
    delX = dfdx\-f;
    xCurrent = xCurrent + delX;

end

end

%[appendix]{"version":"1.0"}
%---
