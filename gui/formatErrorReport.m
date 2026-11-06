function txt = formatErrorReport(ME)
%FORMATERRORREPORT  Readable error report with the exact failing lines.
%
%   txt = formatErrorReport(ME)
%
%   For the exception and every exception in its cause chain, lists the
%   message, the identifier, and each stack frame as
%       at file.m > function, line N
%            N | <source text of that line>
%   so you can see which statement failed, not just the message.
%
%   Typical use:
%       try
%           report = inspectCircuit('myCircuit.slx');
%       catch ME
%           disp(formatErrorReport(ME));
%       end

lines = appendException({}, ME, 0);
txt = strjoin(lines, newline);
end

function lines = appendException(lines, ME, depth)
pad = repmat('    ', 1, depth);
lines{end + 1} = sprintf('%sError: %s', pad, ME.message);
if ~isempty(ME.identifier)
    lines{end + 1} = sprintf('%s  Identifier: %s', pad, ME.identifier);
end
for k = 1:numel(ME.stack)
    s = ME.stack(k);
    [~, f, e] = fileparts(s.file);
    lines{end + 1} = sprintf('%s  at %s%s > %s, line %d', pad, f, e, s.name, s.line); %#ok<AGROW>
    code = sourceLine(s.file, s.line);
    if ~isempty(code)
        lines{end + 1} = sprintf('%s       %d | %s', pad, s.line, code); %#ok<AGROW>
    end
end
for c = 1:numel(ME.cause)
    lines{end + 1} = sprintf('%s  Caused by:', pad); %#ok<AGROW>
    lines = appendException(lines, ME.cause{c}, depth + 1);
end
end

function code = sourceLine(file, lineNo)
% Read one line of a plain-text source file. Binary files (.mlapp, .p, .slx)
% cannot be read this way; for an .mlapp, the line number refers to Code View.
code = '';
[~, ~, ext] = fileparts(file);
if ~strcmpi(ext, '.m') || ~isfile(file) || lineNo < 1
    return
end
try
    textLines = splitlines(string(fileread(file)));
    if lineNo <= numel(textLines)
        code = strtrim(char(textLines(lineNo)));
    end
catch
end
end
