function assembled = assemble(array, xCurrent, t, lnth, type)

% CHECK TYPE


% B, length x column vector
if (type == "B")
    canvas = zeros(lnth(1),1);

    for n = 1: size(array,1)
        if (array{n,3})
            canvas = canvas + array{n,1}*array{n,2}(t);
        else
            canvas = canvas + array{n,1}*array{n,2};
        end
    end
    assembled = canvas;
end

% dCxdp and dGxdp, size x by p matrix
if (type == "C")
    canvas = zeros(lnth(1),lnth(2));

    for n = 1:size(array,1)
        if (array{n,2}(1)~=0)   
            if (array{n,2}(2)~=0)
                canvas(:,n) = array{n,1}*( xCurrent(array{n,2}(1)) - xCurrent(array{n,2}(2)) );
            else
                canvas(:,n) = array{n,1}*( xCurrent(array{n,2}(1)));
            end
        else
            canvas(:,n) = array{n,1}*(0);
        end
    end
    assembled = canvas;
end


% F, length x column vector
if (type == "F")
    canvas = zeros(lnth(1),1);

    for n = 1: size(array,1)
        if (array{n,3}(2) ~=0)
            canvas = canvas + array{n,1}*array{n,2}(  xCurrent(array{n,3}(1)), xCurrent(array{n,3}(2))  );
        else
            canvas = canvas + array{n,1}*array{n,2}(  xCurrent(array{n,3}(1)), 0  );
        end
    end
    assembled = canvas;
end


% dFdx, size x by x matrix
if (type == "dF")
    canvas = zeros(lnth(1),lnth(1));

    for n = 1: size(array,1)
        if (array{n,3}(2) ~=0)
            canvas = canvas + array{n,1}*array{n,2}(  xCurrent(array{n,3}(1)), xCurrent(array{n,3}(2))  );
        else
            canvas = canvas + array{n,1}*array{n,2}(  xCurrent(array{n,3}(1)), 0  );
        end
    end
    assembled = canvas;
end


end

%[appendix]{"version":"1.0"}
%---
