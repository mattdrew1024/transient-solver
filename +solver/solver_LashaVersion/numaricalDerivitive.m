function dxdt = numaricalDerivitive(x,h,numTimeSteps)

% Creating the x matricies the same size as x
dxdtShifted = x;
dxdt = x;

disp(dxdtShifted)
% Taking the derivitive.  This gives us the values corosponding to a t that
% is shifted by h/2
for n = 1:numTimeSteps-1
    dxdtShifted(:,n) = (x(:,n+1)-x(:,n))/h;
end

% Shifting back to match the origional t values, we take each point and subtract the average of the point
% and the one before
for n = 2:numTimeSteps-1
    dxdt(:,n) = dxdtShifted(:,n) - (dxdtShifted(:,n) - dxdtShifted(:,n-1))/2;
end

end

%[appendix]{"version":"1.0"}
%---
