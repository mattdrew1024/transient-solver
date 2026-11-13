function [xNomPlot, MPlot,x,M,t] = runSolver(C, dCxdp, G, dGxdp, F, dFdx, B, lnth, h, time, path)


% Make sure inputs are of the correct form
% UNFINISHED


% SETUP

% Set up xNom, t, and M
numTimeSteps = time/h +1;
x = zeros(lnth(1),numTimeSteps);
t = zeros(1,numTimeSteps);
for i = 1:numTimeSteps
    t(i) = h*(i-1);
end
Mn = x;
M = cell(1,lnth(2));






% PATHS TO SOLVE XNOM AND M

% Path 0
if (path == 0)
    
    % x nominal
    for n = 1:numTimeSteps
        x(:,n)=G\assemble(B,0,t(n),lnth,"B");
    end

    % M
    for m = 1:lnth(2)
        for n = 1:numTimeSteps
            dGn = assemble(dGxdp, x(:,n), 0, lnth, "C");
            Mn(:,n) = G\-dGn(:,m);
        end
        M{m} = Mn;
    end
end


% Path 1

if (path == 1)

    % x nominal
    xGuess = zeros(lnth(1),1); %THIS IS A PLACEHOLDER AND NEEDS TO CHANGE TO A REAL GUESS

    for n = 1:numTimeSteps
        V = assemble(B, xGuess, t(n), lnth, "B");
        xConverged = newtonIterate(xGuess, G, V, F, dFdx, 0, h, lnth);
        x(:,n)=xConverged;
    end

    % M
    for m = 1:lnth(2)
        for n = 1:numTimeSteps
            dGn = assemble(dGxdp, x(:,n), 0, lnth, "C");
            dFn = assemble(dFdx, x(:,n), 0, lnth, "dF");
            Mn(:,n) = (G+dFn)\-dGn(:,m);
        end
        M{m} = Mn;
    end
end


% Path 2 - x nominal

if (path == 2)
    xCurrent = zeros(lnth(1),1); %THIS IS A PLACEHOLDER AND NEEDS TO CHANGE TO A REAL GUESS

    for n = 1:numTimeSteps-1
        x(:,n) = xCurrent;
        BNext = assemble(B,xCurrent,t(n+1),lnth,"B");

        xNext = (G + (C/h))\(BNext + ((C/h)*xCurrent));
        xCurrent = xNext;
    end   
end



% Path 3- x nominal

if (path == 3)
    xCurrent = zeros(lnth(1),1); %THIS IS A PLACEHOLDER AND NEEDS TO CHANGE TO A REAL GUESS

    for n=1:numTimeSteps-1
        x(:,n) = xCurrent;
        BNext = assemble(B,xCurrent,t(n+1),lnth,"B");
        V = BNext + (C/h)*xCurrent;

        xNext = newtonIterate(xCurrent, G, V, F, dFdx, C, h, lnth);
        xCurrent = xNext;
    end
end



% M for path 2 and 3

if ((path == 2)||(path == 3))
    
    % Derivitive of x nominal
    dxdt = numaricalDerivitive(x,h,numTimeSteps);
  
    % M
    for m = 1:lnth(2)
        mCurrent = zeros(lnth(1),1); %THIS IS A PLACEHOLDER AND NEEDS TO CHANGE TO A REAL GUESS
        for n = 1:numTimeSteps-1
            Mn(:,n) = mCurrent;
            dGn = assemble(dGxdp,x(:,n+1),0,lnth,"C");
            dCn = assemble(dCxdp,dxdt(:,n+1),0,lnth,"C");
            if (path == 3)
                dFn = assemble(dFdx,x(:,n+1),0,lnth,"dF");
            else
                dFn = 0;
            end
           
    
            mNext = (C/h + G + dFn)\( (C/h)*mCurrent - dGn(:,m) - dCn(:,m) );
            mCurrent = mNext;
        end
        M{m} = Mn;
    end
end


% OUTPUTS: PLOTS

% plot x nominal
figXNom = figure;
hold on
grid on
xlim([t(1), t(end)]);
ylim([min(x(:)), max(x(:))]);
xlabel("t");
ylabel("x(t)");
title("Plot of x(t) nominal");
for n = 1:lnth(1)
    plot(t,x(n,:));
end
legend(arrayfun(@(i) sprintf('X%d',i), 1:lnth(1), 'UniformOutput', false));
hold off
xNomPlot = figXNom;

% plot M
MPlot = zeros(1,lnth(2));
for m = 1:lnth(2)
    figMn = figure;
    hold on
    grid on
    xlim([t(1), t(end)]);
    ylim([min(M{m}(:)), max(M{m}(:))]);
    xlabel("t");
    ylabel("dX/dp(t)");
    title(sprintf("Plot of dX/dp(t) for Parameter %d",m));
    for n = 1:lnth(1)
        plot(t,M{m}(n,:));
    end
    legend(arrayfun(@(i) sprintf('dX%d/dp',i), 1:lnth(1), 'UniformOutput', false));
    hold off
    MPlot(m) = figMn;
end


end

%[appendix]{"version":"1.0"}
%---
