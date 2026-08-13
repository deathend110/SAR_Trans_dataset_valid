clear;clc;close all;

%% 单次RxAx混合上采样实验代码，验证方位向和距离向的同步上采样混合策略
%% ==================== 参数加载 ====================
S60 = load("FS60_params.mat");
% RT / mixed 参数
seed = 42;
rng(seed);
Azimuth_q_m     = 1.5;       % 混合AR上采样的单独方位向上采样倍率
Range_q_m       = 1.7;       % 混合AR上采样的单独距离向上采样倍率
q               = Azimuth_q_m*Range_q_m; % 整体的上采样倍率

Azimuth_q       = q;       % 方位向上采样倍率
Range_q         = q;       % 方位向上采样倍率
As              = 0.6;     % RT 阈值系数

%% 加载回波数据和成像参数
data_figure = "SAR_Dataset_city2_histeq";
data_folder = replace("G:\MATLAB-G\SAR Full PSF\temp\", "temp", data_figure);
data_name = "rstart 301.mat";
data = load(data_folder+data_name).channel_1;
c_start = 6500;
channel_1 = data(:, c_start:c_start+S60.nrn-1);
signal60_input = channel_1(1:3:end, :);

%% 载入该底图归一化参数文件
% % 全方位向
% Azimuth_THpath = fullfile(data_folder, data_figure + "_azimuthq"+ num2str(Azimuth_q) + ".mat");
% Azimuth_Meta = load(Azimuth_THpath);
% % 全距离向
% Range_THpath = fullfile(data_folder, data_figure + "_rangeq"+ num2str(Range_q) + ".mat");
% Range_Meta = load(Range_THpath);


%% GT
RC_gt   = Range_Compress(signal60_input, S60.fc, S60.tnrn, S60.gama, S60.R0, S60.C, S60.Fs, S60.Tp);
RCMC_gt = RCMC(RC_gt, S60.lambda, S60.fnrn, S60.fnan, S60.R0, S60.C, S60.v);
IMG_gt  = SAR_Imaging(RCMC_gt, S60.lambda, S60.Fs, S60.R0, S60.C, S60.v, S60.tnan, S60.Ta, S60.prf);
roi_gt = abs(IMG_gt(S60.nrn/2-S60.R_total/2+1:S60.nrn/2+S60.R_total/2, S60.nan/2-S60.A_num/2:S60.nan/2+S60.A_num/2-1));
% img_gt = single(minmaxnormalize_image(roi_gt, Azimuth_Meta.V_MAX_GT_L, Azimuth_Meta.V_MIN_GT_L));
img_gt = normalize_image(roi_gt);
subplot(221);imagesc(img_gt);axis image;colorbar;title("GT As: "+num2str(As));

%% Azimuth Upsample
% 生成RT噪声
[U_master_patch, ~, ~] = Azimuth_Build_RT(signal60_input, Azimuth_q, As);

% 上采样
signal60_patch_high = azimuth_upsample_fft(signal60_input, Azimuth_q);
% RT阈值1bit量化
channel_1bit_high = quantize_1bit_with_U(signal60_patch_high, U_master_patch);
% RC
RC_high = Range_Compress(channel_1bit_high, S60.fc, S60.tnrn, S60.gama, S60.R0, S60.C, S60.Fs, S60.Tp);
% 下采样
RC_crop = crop_azimuth_doppler_to_width(RC_high, S60.nan);
% 低采样率参数下继续成像
RCMC_crop = RCMC(RC_crop, S60.lambda, S60.fnrn, S60.fnan, S60.R0, S60.C, S60.v);
IMG_high  = SAR_Imaging(RCMC_crop, S60.lambda, S60.Fs, S60.R0, S60.C, S60.v, S60.tnan, S60.Ta, S60.prf);
roi_crop = abs(IMG_high(S60.nrn/2-S60.R_total/2+1:S60.nrn/2+S60.R_total/2, S60.nan/2-S60.A_num/2:S60.nan/2+S60.A_num/2-1));
% Azimuth_Upsample = single(minmaxnormalize_image(roi_crop, Azimuth_Meta.V_MAX_Q_L, Azimuth_Meta.V_MIN_Q_L));
Azimuth_Upsample = normalize_image(roi_crop);
Azimuth_title = [
    "Azimuth Upsample q" + num2str(Azimuth_q) + " 1bit"; 
    "SSIM: " + num2str(ssim(Azimuth_Upsample, img_gt))+"   PSNR: " + num2str(psnr(Azimuth_Upsample, img_gt))
];
subplot(222);imagesc(Azimuth_Upsample);axis image;colorbar;title(Azimuth_title);

%% Range Upsample
% 生成RT噪声
[U_master_patch, ~, ~] = Range_Build_RT(signal60_input, Range_q, As);

% 上采样
signal60_patch_high = range_upsample_fft(signal60_input, Range_q);
% ==================================================================================================
% 构造上采样后对应的RD参数 
nrn_up = size(signal60_patch_high, 1);
Fs_up  = Range_q * S60.Fs;
Tnrn_up   = 1 / Fs_up;
Tstart_up = 2 * S60.R0 / S60.C - nrn_up / 2 / Fs_up;
Tend_up   = 2 * S60.R0 / S60.C + (nrn_up / 2 - 1) / Fs_up;
tnrn_up   = (Tstart_up : Tnrn_up : Tend_up).';
% ==================================================================================================
% RT阈值1bit量化
channel_1bit_high = quantize_1bit_with_U(signal60_patch_high, U_master_patch);
% RC
RC_high = Range_Compress(channel_1bit_high, S60.fc, tnrn_up, S60.gama, S60.R0, S60.C, Fs_up, S60.Tp);
% 下采样
RC_crop = crop_range_doppler_to_width(RC_high, S60.nrn);
% 低采样率参数下继续成像
RCMC_crop = RCMC(RC_crop, S60.lambda, S60.fnrn, S60.fnan, S60.R0, S60.C, S60.v);
IMG_high  = SAR_Imaging(RCMC_crop, S60.lambda, S60.Fs, S60.R0, S60.C, S60.v, S60.tnan, S60.Ta, S60.prf);
roi_crop = abs(IMG_high(S60.nrn/2-S60.R_total/2+1:S60.nrn/2+S60.R_total/2, S60.nan/2-S60.A_num/2:S60.nan/2+S60.A_num/2-1));
% Range_Upsample = single(minmaxnormalize_image(roi_crop, Range_Meta.V_MAX_Q_L, Range_Meta.V_MIN_Q_L));
Range_Upsample = normalize_image(roi_crop);
Range_title = [
    "Range Upsample q" + num2str(Range_q) + " 1bit"; 
    "SSIM: " + num2str(ssim(Range_Upsample, img_gt))+"   PSNR: " + num2str(psnr(Range_Upsample, img_gt))
];
subplot(223);imagesc(Range_Upsample);axis image;colorbar;title(Range_title);

%% Azimuth-Range MixUpsample
% 生成2D RT阈值
[U_master_patch, sigma, A_rt] = Build_2D_SplitRT(signal60_input, Azimuth_q_m, Range_q_m, As);

% 上采样
signal60_patch_high = two_dim_upsample_fft(signal60_input, Azimuth_q_m, Range_q_m);
% ==================================================================================================
% 构造距离上采样后对应的RD参数 
nrn_up = size(signal60_patch_high, 1);
Fs_up  = Range_q_m * S60.Fs;
Tnrn_up   = 1 / Fs_up;
Tstart_up = 2 * S60.R0 / S60.C - nrn_up / 2 / Fs_up;
Tend_up   = 2 * S60.R0 / S60.C + (nrn_up / 2 - 1) / Fs_up;
tnrn_up   = (Tstart_up : Tnrn_up : Tend_up).';
% ==================================================================================================

% RT阈值1bit量化
channel_1bit_high = quantize_1bit_with_U(signal60_patch_high, U_master_patch);
% RC
RC_high = Range_Compress(channel_1bit_high, S60.fc, tnrn_up, S60.gama, S60.R0, S60.C, Fs_up, S60.Tp);

% 下采样
RC_crop = two_dim_downsample_fft(RC_high, Azimuth_q_m, Range_q_m, S60);

% 低采样率参数下继续成像
RCMC_crop = RCMC(RC_crop, S60.lambda, S60.fnrn, S60.fnan, S60.R0, S60.C, S60.v);
IMG_high  = SAR_Imaging(RCMC_crop, S60.lambda, S60.Fs, S60.R0, S60.C, S60.v, S60.tnan, S60.Ta, S60.prf);
roi_crop = abs(IMG_high(S60.nrn/2-S60.R_total/2+1:S60.nrn/2+S60.R_total/2, S60.nan/2-S60.A_num/2:S60.nan/2+S60.A_num/2-1));
% Azimuth_Range_Upsample = single(minmaxnormalize_image(roi_crop, Range_Meta.V_MAX_Q_L, Range_Meta.V_MIN_Q_L));
Azimuth_Range_Upsample = normalize_image(roi_crop);
Azimuth_Range_title = [
    "Azimuth-Range MixUpsample q" + num2str(q) + " 1bit"; 
    "SSIM: " + num2str(ssim(Azimuth_Range_Upsample, img_gt))+"   PSNR: " + num2str(psnr(Azimuth_Range_Upsample, img_gt))
];
subplot(224);imagesc(Azimuth_Range_Upsample);axis image;colorbar;title(Azimuth_Range_title);
% movegui('center');


%% =========================================================
%% =================== assistant function ==================
%% =========================================================
% 一次生成方位向全局RT阈值
function [U, sigma, A_rt] = Azimuth_Build_RT(input60, Azimuth_q, As)
    signal_up = azimuth_upsample_fft(input60, Azimuth_q);   % [1200 x (q*2992)]

    sigma = sqrt(2 / pi) * mean(abs(signal_up(:)));
    A_rt = As * sigma;

    phi = 2 * pi * rand(1, size(signal_up, 2));     % 序列级唯一随机相位
    U = A_rt * exp(1i * phi);         % [1 x (q*2992)]
end

% 一次生成距离向全局RT阈值
function [U, sigma, A_rt] = Range_Build_RT(input60, Range_q, As)
    signal_up = range_upsample_fft(input60, Range_q);   % [q*1200 x 2992]
    
    % 上采样后的阈值和没有上采样的阈值是一致的，这里可以统一用sigma
    sigma = sqrt(2 / pi) * mean(abs(signal_up(:)));
    A_rt = As * sigma;

    phi = 2 * pi * rand(size(signal_up, 1), 1);     % 序列级唯一随机相位
    U = A_rt * exp(1i * phi);         % [q*1200 x 1]
end

% 2维上采样，先距离再方位。
% 理论上两者间的顺序不影响
function S_up = two_dim_upsample_fft(S, q_azimuth, q_range)
    S_up = S;

    if q_range > 1
        S_up = range_upsample_fft(S_up, q_range);
    end

    if q_azimuth > 1
        S_up = azimuth_upsample_fft(S_up, q_azimuth);
    end
end

% 2维下采样
function S_down = two_dim_downsample_fft(S, q_azimuth, q_range, meta)
    S_down = S;
    if q_azimuth > 1
        S_down = crop_azimuth_doppler_to_width(S_down, meta.nan);
    end

    if q_range > 1
        S_down = crop_range_doppler_to_width(S_down, meta.nrn);
    end
    
    
end

% 一次生成二维 full RT 阈值场
function [U, sigma, A_rt] = Build_2D_RT(input60, Azimuth_q, Range_q, As)
    signal_up = two_dim_upsample_fft(input60, Azimuth_q, Range_q);

    sigma = sqrt(2 / pi) * mean(abs(signal_up(:)));
    A_rt = As * sigma;

    phi = 2 * pi * rand(size(signal_up));
    U = A_rt * exp(1i * phi);
end

% 生成可分离的二维 RT 阈值场
% 先构造一个距离向列相位向量，再构造一个方位向行相位向量，然后按点组合成 2D 相位场
function [U, sigma, A_rt] = Build_2D_SplitRT(input60, Azimuth_q, Range_q, As)
    signal_up_2d = two_dim_upsample_fft(input60, Azimuth_q, Range_q);
    [Nr_up, Na_up] = size(signal_up_2d);

    phi_r = 2 * pi * rand(Nr_up, 1);
    phi_a = 2 * pi * rand(1, Na_up);

    sigma = sqrt(2 / pi) * mean(abs(signal_up_2d(:)));
    A_rt = As * sigma;

    U = A_rt * exp(1i * (phi_r + phi_a));
end



% 附带RT阈值的1bit量化
function S1 = quantize_1bit_with_U(S, U)
    re = ones(size(S), 'like', real(S));
    im = ones(size(S), 'like', real(S));

    re(real(S) + real(U) < 0) = -1;
    im(imag(S) + imag(U) < 0) = -1;

    S1 = complex(re, im);
end

% 距离向上采样
function S_up = range_upsample_fft(S, q)
    [Nr, Na] = size(S);
    Nr_up = q * Nr;

    Sf = fftshift(fft(S, [], 1), 1);

    pad_total = Nr_up - Nr;
    pad_top    = floor(pad_total / 2);
    pad_bottom = pad_total - pad_top;

    Sf_up = [zeros(pad_top, Na, 'like', Sf); ...
             Sf; ...
             zeros(pad_bottom, Na, 'like', Sf)];

    S_up = ifft(ifftshift(Sf_up, 1), [], 1) * q;
end

%% 距离向FFT下采样
function X_crop = crop_range_doppler_to_width(X, target_height)
    [Nr_up, ~] = size(X);
    if target_height > Nr_up
        error('target_height cannot be larger than current height.');
    end

    Xf = fftshift(fft(X, [], 1), 1);

    c = floor(Nr_up/2) + 1;
    h = floor(target_height/2);

    if mod(target_height, 2) == 0
        idx = (c-h):(c+h-1);
    else
        idx = (c-h):(c+h);
    end

    Xf_crop = Xf(idx, :);
    X_crop = ifft(ifftshift(Xf_crop, 1), [], 1);
end



%% 方位向上采样
function S_up = azimuth_upsample_fft(S, q)
    [Nr, Na] = size(S);
    Na_up = q * Na;

    Sf = fftshift(fft(S, [], 2), 2);

    pad_total = Na_up - Na;
    pad_left  = floor(pad_total / 2);
    pad_right = pad_total - pad_left;

    Sf_up = [zeros(Nr, pad_left, 'like', Sf), ...
             Sf, ...
             zeros(Nr, pad_right, 'like', Sf)];

    S_up = ifft(ifftshift(Sf_up, 2), [], 2) * q;
end

%% 方位向FFT下采样
function X_crop = crop_azimuth_doppler_to_width(X, target_width)
    [~, Na_up] = size(X);
    if target_width > Na_up
        error('target_width cannot be larger than current width.');
    end

    Xf = fftshift(fft(X, [], 2), 2);

    c = floor(Na_up/2) + 1;
    h = floor(target_width/2);

    if mod(target_width, 2) == 0
        idx = (c-h):(c+h-1);
    else
        idx = (c-h):(c+h);
    end

    Xf_crop = Xf(:, idx);
    X_crop = ifft(ifftshift(Xf_crop, 2), [], 2);
end

