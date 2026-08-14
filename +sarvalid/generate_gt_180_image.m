function image_patch = generate_gt_180_image(signal180, S180, patch_size)
%GENERATE_GT_180_IMAGE 180 MHz直接RD成像并投影到600行共同物理网格。

arguments
    signal180
    S180 (1, 1) struct
    patch_size (1, 1) double {mustBePositive, mustBeInteger} = 512
end
RC = Range_Compress(signal180, S180.fc, S180.tnrn, S180.gama, ...
    S180.R0, S180.C, S180.Fs, S180.Tp);
RCMC_out = RCMC(RC, S180.lambda, S180.fnrn, S180.fnan, ...
    S180.R0, S180.C, S180.v);
image_complex = SAR_Imaging(RCMC_out, S180.lambda, S180.Fs, ...
    S180.R0, S180.C, S180.v, S180.tnan, S180.Ta, S180.prf);

row_start = S180.nrn / 2 - S180.R_total / 2 + 1;
row_end = S180.nrn / 2 + S180.R_total / 2;
col_start = S180.nan / 2 - S180.A_num / 2;
col_end = S180.nan / 2 + S180.A_num / 2 - 1;
roi_complex = image_complex(row_start:row_end, col_start:col_end);
roi_common = sarvalid.crop_spectrum(roi_complex, 600, 1);
image_patch = sarvalid.crop_center(abs(roi_common), patch_size);
end
