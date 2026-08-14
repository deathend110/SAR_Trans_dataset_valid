function [image_patch, RC_gt] = generate_gt_image(signal, S60, patch_size)
%GENERATE_GT_IMAGE 由60 MHz clean复回波生成统一GT幅度图。

arguments
    signal
    S60 (1, 1) struct
    patch_size (1, 1) double {mustBePositive, mustBeInteger} = 512
end

RC_gt = Range_Compress(signal, S60.fc, S60.tnrn, S60.gama, ...
    S60.R0, S60.C, S60.Fs, S60.Tp);
[image_patch, ~] = sarvalid.focus_base_rc(RC_gt, S60, patch_size);
end
