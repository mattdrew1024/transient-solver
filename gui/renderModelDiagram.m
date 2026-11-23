function [imageFile, info] = renderModelDiagram(modelFile, outFolder)
%RENDERMODELDIAGRAM  Get the preview image stored inside a .slx file.
%
%   [imageFile, info] = renderModelDiagram(modelFile)
%   [imageFile, info] = renderModelDiagram(modelFile, outFolder)
%   renderModelDiagram                 % no input: pick a file, show the preview
%
%   modelFile  full path of a .slx file
%   outFolder  where to write the PNG (default: tempdir/CircuitInspector)
%
%   imageFile  full path of the extracted PNG
%   info       struct with fields ModelName, File, FileDate, Method, Note
%
%   A .slx file is a zip package. When Simulink saves a model it also
%   stores a picture of the top-level diagram as metadata/thumbnail.png.
%   This function only copies that picture out of the file: the model is
%   never loaded, so it is fast, needs no Simulink license, and cannot
%   clash with a model of the same name that is already loaded.
%
%   The preview shows the model as it was the last time it was saved.
%   .mdl files have no stored preview.
%
%   Called with no model file (for example with the Editor's Run button),
%   it asks for one. Called with no output arguments, it shows the picture
%   in a figure window.

if nargin < 1 || isempty(modelFile)
    [f, p] = uigetfile({'*.slx', 'Simulink models (*.slx)'}, ...
        'Select a Simulink model to preview');
    if isequal(f, 0)
        imageFile = '';
        info = struct([]);
        return
    end
    modelFile = fullfile(p, f);
end
if nargin < 2 || isempty(outFolder)
    outFolder = fullfile(tempdir, 'CircuitInspector');
end
modelFile = char(modelFile);
if ~isfile(modelFile)
    error('renderModelDiagram:noFile', 'File not found: %s', modelFile);
end
[~, name, ext] = fileparts(modelFile);
if ~strcmpi(ext, '.slx')
    error('renderModelDiagram:notSlx', ...
        '%s is a %s file. Only .slx files contain a stored preview.', [name ext], ext);
end
if ~isfolder(outFolder)
    mkdir(outFolder);
end

d = dir(modelFile);
info = struct('ModelName', name, 'File', modelFile, ...
    'FileDate', char(datetime(d.datenum, 'ConvertFrom', 'datenum', 'Format', 'yyyy-MM-dd HH:mm')), ...
    'Method', 'thumbnail', ...
    'Note', 'Preview stored in the file (as of its last save).');

% A unique name each time, so the app never shows a cached older picture.
imageFile = [tempname(outFolder) '.png'];
extractThumbnail(modelFile, imageFile);

if nargout == 0
    showPreview(imageFile, info);
    clear imageFile
end
end

% ---------------------------------------------------------------------

function extractThumbnail(slxFile, imageFile)
% Unzip the package into a temporary folder and copy the preview out.
tmp = tempname;
cleaner = onCleanup(@() removeFolder(tmp));
try
    files = unzip(slxFile, tmp);
catch ME
    error('renderModelDiagram:unzip', 'Could not open %s as a .slx package: %s', ...
        slxFile, ME.message);
end
hit = files(endsWith(strrep(files, '\', '/'), 'metadata/thumbnail.png'));
if isempty(hit)
    error('renderModelDiagram:noThumbnail', ['%s has no stored preview ' ...
        '(metadata/thumbnail.png). Open the model in Simulink and save it once ' ...
        'to create one.'], slxFile);
end
copyfile(hit{1}, imageFile);
clear cleaner
end

function removeFolder(folder)
if isfolder(folder)
    rmdir(folder, 's');
end
end

function showPreview(imageFile, info)
fig = uifigure('Name', ['Preview: ' info.ModelName]);
g = uigridlayout(fig, [2 1]);
g.RowHeight = {'fit', '1x'};
uilabel(g, 'WordWrap', 'on', 'Text', sprintf('%s  |  %s  |  saved %s', ...
    info.ModelName, info.File, info.FileDate));
uiimage(g, 'ImageSource', imageFile, 'ScaleMethod', 'fit');
end
