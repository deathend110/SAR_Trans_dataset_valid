function [image_patch, meta] = focus_base_rc(RC_base, S60, patch_size)
%FOCUS_BASE_RC 从统一RC网格完成RCMC、方位压缩和中心裁剪。

arguments
    RC_base
    S60 (1, 1) struct
    patch_size (1, 1) double {mustBePositive, mustBeInteger} = 512
end

expected_size = [S60.nrn, S60.nan];
if ~isequal(size(RC_base), expected_size)
    error('sarvalid:FocusInputSizeMismatch', ...
        '成像RC必须为FS60基网格%s，实际为%s。', ...
        mat2str(expected_size), mat2str(size(RC_base)));
end

RCMC_out = RCMC(RC_base, S60.lambda, S60.fnrn, S60.fnan, ...
    S60.R0, S60.C, S60.v);
image_complex = SAR_Imaging(RCMC_out, S60.lambda, S60.Fs, ...
    S60.R0, S60.C, S60.v, S60.tnan, S60.Ta, S60.prf);

row_start = S60.nrn / 2 - S60.R_total / 2 + 1;
row_end = S60.nrn / 2 + S60.R_total / 2;
col_start = S60.nan / 2 - S60.A_num / 2;
col_end = S60.nan / 2 + S60.A_num / 2 - 1;
roi = abs(image_complex(row_start:row_end, col_start:col_end));
image_patch = sarvalid.crop_center(roi, patch_size);

meta = struct("roi_size", size(roi), "patch_size", size(image_patch));
end
