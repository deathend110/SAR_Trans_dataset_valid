clear; clc; close all;

%% =========================================================
%  主脚本：生成距离向 mixed 采样率序列数据集（9帧，去高斯噪声净化版）
%  当前脚本对应 q_high=2.5，q_low=1.5 在距离向RC结果上构造 q倍上采样链路和60MHz链路，再按序列掩码拼接。
%
%  核心逻辑：
%  1) 全局512有效轴为 H(512)-L(512)-H(512)，对应帧模式：1高-3混-1低-3混-1高。
%  2) 每条序列先切 1200x2224 的 60MHz 大块，再逐帧取 1200x1200 patch。
%  3) 序列级生成同一个 master 随机相位RT阈值场，距离向上采样后沿距离维扩展。
%  4) high帧走距离向 q_high 倍上采样RT 1-bit链路；low帧走q_low 倍 RT 1-bit链路。
%  5) mixed帧先分别得到 high/low 的距离压缩结果，再按 mode_mask_1200 能量对齐并拼接后成像。
%  6) 成像ROI为600x600，中心裁成512x512，HDF5(.mat)仅保存Linear一套序列。
%% =========================================================

%% ==================== 配置区 ====================
DIR_LIST = ["SAR_Dataset_Bangkok_1", "SAR_Dataset_city1_histeq", ...
            "SAR_Dataset_city2_histeq", "SAR_Dataset_SAR_figure", ...
            "SAR_Dataset_filed", "SAR_Dataset_port", "SAR_Dataset_suburb"];

% 序列参数
N_SEQ          = 9;
STEP           = 128;
SEQ_STEP       = 3 * STEP;       % 序列之间滑动步长，可调整
SIG_H          = 1200;           % 每帧输入信号高度
SIG_W          = 1200;           % 每帧输入信号宽度
IMG_VALID      = 600;            % 成像后有效区域大小
PATCH_SIZE     = 512;            % 最终入序列 patch
VALID_MARGIN   = (SIG_W - PATCH_SIZE) / 2;   % 344
LOGIC_LEN_512  = PATCH_SIZE + (N_SEQ - 1) * STEP;   % 1536
INPUT_LEN_1200 = SIG_W      + (N_SEQ - 1) * STEP;   % 2224

% RT / mixed 参数
q_high        = 2.5;     % 距离向高上采样倍率
q_low         = 1.5;     % 距离向上采样倍率
q_lcm         = quick_lcm(q_low, q_high);     % 距离向上采样倍率最小公倍数

As            = 0.6;     % RT 阈值系数
EDGE_BUFFER   = 64;      % mixed 能量对齐 buffer

% 数据集命名
BASE_TAG = "RangeMix_high" + string(q_high) + "_low" + string(q_low) +"_Length"+ string(N_SEQ) + "_rt";

rng(42);

%% ==================== 参数加载 ====================
S60 = load("FS60_params.mat");

% 高低采样率mask
% 512（高）——512（低）——512（高）
global_mode_mask_512 = build_global_mode_mask_512(LOGIC_LEN_512);

%% ==================== 输出目录 ====================
BASE_DIR = BASE_TAG;
if ~exist(BASE_DIR, 'dir'), mkdir(BASE_DIR); end
disp(BASE_DIR);

TRAIN_L_DIR  = fullfile(BASE_DIR, 'Linear', 'traindata');
TEST_L_DIR   = fullfile(BASE_DIR, 'Linear', 'testdata');

if ~exist(TRAIN_L_DIR,  'dir'), mkdir(TRAIN_L_DIR);  end
if ~exist(TEST_L_DIR,   'dir'), mkdir(TEST_L_DIR);   end

global_train_idx = 1;
global_test_idx  = 1;

BASE_ROOT= "G:\MATLAB-G\SAR Full PSF\";
for d = 1:length(DIR_LIST)
    tic;
    ROOT_DIR = BASE_ROOT + DIR_LIST(d);
    core_name = strrep(DIR_LIST(d), 'SAR_Dataset_', '');

    % 搜索并排序轨迹文件
    filePattern = fullfile(ROOT_DIR, 'rstart*.mat');
    filestructs = dir(filePattern);
    [~, sort_idx] = sort({filestructs.name});
    filestructs = filestructs(sort_idx);

    num_files = length(filestructs);
    if num_files < 2
        warning('底图 [%s] 下文件不足 2 个，跳过。', ROOT_DIR);
        continue;
    end

    % 90% / 10% 划分 test
    num_test = round(num_files * 0.10);
    if num_test == 0 && num_files >= 2
        num_test = 1;
    end

    train_files = filestructs(1 : end - num_test);
    test_files  = filestructs(end - num_test + 1 : end);

    % 载入该底图归一化参数文件
    save_path = DIR_LIST(d) + "_rangeq"+ num2str(q_high) + ".mat";
    THpath = fullfile(ROOT_DIR, save_path);
    q_high_meta = load(THpath);

    save_path = DIR_LIST(d) + "_rangeq"+ num2str(q_low) + ".mat";
    THpath = fullfile(ROOT_DIR, save_path);
    q_low_meta = load(THpath);

    fprintf('\n[%s] 共 %d 条轨迹 | 训练集: %d 条 (%.1f%%) | 测试集: %d 条\n', ...
        ROOT_DIR, num_files, length(train_files), ...
        (length(train_files) / num_files) * 100, length(test_files));

    split_sets  = {train_files, test_files};
    split_names = {'Train', 'Test'};

    for split_id = 1:2
        current_files = split_sets{split_id};
        current_mode  = split_names{split_id};

        for i = 1:length(current_files)
            filepath = fullfile(ROOT_DIR, current_files(i).name);
            fprintf('  正在处理 [%s]: %s\n', current_mode, current_files(i).name);

            tempData = load(filepath);
            varNames = fieldnames(tempData);
            raw_data = tempData.(varNames{1});    % 原始高采样率回波

            % 不再加高斯噪声，直接构造 60MHz clean / input 母体 1200x18000
            channel_60_clean = raw_data(1:3:end, :);
            channel_60_input = channel_60_clean;

            [h60, width60] = size(channel_60_clean);

            % 能切出 1200x2224 大块的起点
            max_start = width60 - INPUT_LEN_1200 + 1;
            if max_start < 1
                continue;
            end

            block_starts = 1 : SEQ_STEP : max_start;
            if block_starts(end) < max_start
                block_starts(end + 1) = max_start;
            end

            for block_start = block_starts
                % ========== 切当前序列的大块：1200 x 2224 ==========
                seq60_clean = extract_sequence_block_60mhz(channel_60_clean, block_start, SIG_H, INPUT_LEN_1200);
                seq60_input = extract_sequence_block_60mhz(channel_60_input, block_start, SIG_H, INPUT_LEN_1200);

                % ========== 序列级 master 阈值场（无高斯噪声） ==========
                % 为了满足生成一次RT阈值的要求，我们用qh和ql的最小公倍数来生成，
                % 这样产出的RT阈值可以被1:q_lcm/qh(ql):end，整数抽样
                [U_master_seq, sigma_seq, A_rt] = build_master_threshold_seq(seq60_input, q_lcm, As);

                % ========== 序列容器 ==========
                seq_GT_L    = zeros(PATCH_SIZE, PATCH_SIZE, N_SEQ, 'single');
                seq_input_L = zeros(PATCH_SIZE, PATCH_SIZE, N_SEQ, 'single');

                frame_mode_id     = zeros(1, N_SEQ, 'uint8');
                mode_mask_512_all = zeros(N_SEQ, PATCH_SIZE, 'uint8');

                for k = 1:N_SEQ
                    % ---------- 当前帧 patch ----------
                    [signal60_clean_patch, signal60_input_patch, U_master_patch] = ...
                        get_frame_patches(seq60_clean, seq60_input, U_master_seq, k, STEP, SIG_W);

                    % ---------- 当前帧模式掩码 ----------
                    [mode_mask_512, mode_mask_1200, frame_mode] = ...
                        get_frame_mode_masks(global_mode_mask_512, k, STEP, PATCH_SIZE, SIG_W, VALID_MARGIN);

                    % ---------- GT 成像 ----------
                    RC_gt   = Range_Compress(signal60_clean_patch, S60.fc, S60.tnrn, S60.gama, S60.R0, S60.C, S60.Fs, S60.Tp);
                    RCMC_gt = RCMC(RC_gt, S60.lambda, S60.fnrn, S60.fnan, S60.R0, S60.C, S60.v);
                    IMG_gt  = SAR_Imaging(RCMC_gt, S60.lambda, S60.Fs, S60.R0, S60.C, S60.v, S60.tnan, S60.Ta, S60.prf);
                    roi_gt = abs(IMG_gt(S60.nrn/2-S60.R_total/2+1:S60.nrn/2+S60.R_total/2, S60.nan/2-S60.A_num/2:S60.nan/2+S60.A_num/2-1));
                    norm_L_gt = single(minmaxnormalize_image(roi_gt, q_high_meta.V_MAX_GT_L, q_high_meta.V_MIN_GT_L));
                    seq_GT_L(:,:,k)    = crop_center(norm_L_gt,  PATCH_SIZE);
                    % imagesc(img_gt_l_600);axis image;colormap gray;
                    
                    % ---------- input 成像 ----------
                     switch string(frame_mode)
                        case "low"
                            % 全低采样率
                            % low上采样
                            signal60_patch_low = range_upsample_fft(signal60_input_patch, q_low);
                            % ==================================================================================================
                            % 构造上采样后对应的RD参数 
                            nrn_low = size(signal60_patch_low, 1);
                            Fs_low  = q_low * S60.Fs;
                            Tnrn_low   = 1 / Fs_low;
                            Tstart_low = 2 * S60.R0 / S60.C - nrn_low / 2 / Fs_low;
                            Tend_low   = 2 * S60.R0 / S60.C + (nrn_low / 2 - 1) / Fs_low;
                            tnrn_low   = (Tstart_low : Tnrn_low : Tend_low).';
                            % ==================================================================================================
                            % RT阈值1bit量化
                            channel_1bit_low = quantize_1bit_with_U(signal60_patch_low, U_master_patch(1:q_lcm/q_low:end, :));
                            % RC
                            RC_low  = Range_Compress(channel_1bit_low, S60.fc, tnrn_low, S60.gama, S60.R0, S60.C, Fs_low, S60.Tp);
                            RC_down = crop_range_doppler_to_width(RC_low, S60.nrn);
                            RCMC_low = RCMC(RC_down, S60.lambda, S60.fnrn, S60.fnan, S60.R0, S60.C, S60.v);
                            IMG_low  = SAR_Imaging(RCMC_low, S60.lambda, S60.Fs, S60.R0, S60.C, S60.v, S60.tnan, S60.Ta, S60.prf);
                            roi_low = abs(IMG_low(S60.nrn/2-S60.R_total/2+1:S60.nrn/2+S60.R_total/2, S60.nan/2-S60.A_num/2:S60.nan/2+S60.A_num/2-1));
                            norm_L_low = single(minmaxnormalize_image(roi_low, q_low_meta.V_MAX_Q_L, q_low_meta.V_MIN_Q_L));
                            seq_input_L(:,:,k) = crop_center(norm_L_low,  PATCH_SIZE);
                            % imagesc(norm_L_low);axis image;colormap gray;
                        case "high"
                            % 上采样
                            signal60_patch_high = range_upsample_fft(signal60_input_patch, q_high);
                            % ==================================================================================================
                            % 构造上采样后对应的RD参数 
                            nrn_up = size(signal60_patch_high, 1);
                            Fs_up  = q_high * S60.Fs;
                            Tnrn_up   = 1 / Fs_up;
                            Tstart_up = 2 * S60.R0 / S60.C - nrn_up / 2 / Fs_up;
                            Tend_up   = 2 * S60.R0 / S60.C + (nrn_up / 2 - 1) / Fs_up;
                            tnrn_up   = (Tstart_up : Tnrn_up : Tend_up).';
                            % ==================================================================================================

                            % RT阈值1bit量化
                            t = q_lcm/q_high;
                            channel_1bit_high = quantize_1bit_with_U(signal60_patch_high, U_master_patch(1:q_lcm/q_high:end, :));
                            % RC
                            RC_high = Range_Compress(channel_1bit_high, S60.fc, tnrn_up, S60.gama, S60.R0, S60.C, Fs_up, S60.Tp);
                            % 下采样
                            RC_crop = crop_range_doppler_to_width(RC_high, S60.nrn);
                            % 低采样率参数下继续成像
                            RCMC_crop = RCMC(RC_crop, S60.lambda, S60.fnrn, S60.fnan, S60.R0, S60.C, S60.v);
                            IMG_high  = SAR_Imaging(RCMC_crop, S60.lambda, S60.Fs, S60.R0, S60.C, S60.v, S60.tnan, S60.Ta, S60.prf);
                            roi_crop = abs(IMG_high(S60.nrn/2-S60.R_total/2+1:S60.nrn/2+S60.R_total/2, S60.nan/2-S60.A_num/2:S60.nan/2+S60.A_num/2-1));
                            norm_L_high = single(minmaxnormalize_image(roi_crop, q_high_meta.V_MAX_Q_L, q_high_meta.V_MIN_Q_L));
                            % imagesc(norm_L_high);axis image;colormap gray;
                            % ssim(norm_L_high, img_gt_l_600)
                            % 距离向上采样后再进行 1bit 阈值量化，虽然仍是 1bit 信号，但由于带限插值与相干成像增益，
                            % 重建图像的线性幅度分布可能更接近 60MHz GT，而不再与 180MHz 直降采样链路一致。
                            % roi_crop = roi_crop / prctile(roi_crop(:), 99);
                            seq_input_L(:,:,k) = crop_center(norm_L_high,  PATCH_SIZE);
                            
                        case "mixed"
                            %% high上采样
                            signal60_patch_high = range_upsample_fft(signal60_input_patch, q_high);
                            % ==================================================================================================
                            % 构造上采样后对应的RD参数 
                            nrn_up = size(signal60_patch_high, 1);
                            Fs_up  = q_high * S60.Fs;
                            Tnrn_up   = 1 / Fs_up;
                            Tstart_up = 2 * S60.R0 / S60.C - nrn_up / 2 / Fs_up;
                            Tend_up   = 2 * S60.R0 / S60.C + (nrn_up / 2 - 1) / Fs_up;
                            tnrn_up   = (Tstart_up : Tnrn_up : Tend_up).';
                            % ==================================================================================================

                            % RT阈值1bit量化
                            channel_1bit_high = quantize_1bit_with_U(signal60_patch_high, U_master_patch(1:q_lcm/q_high:end, :));
                            % RC
                            RC_high = Range_Compress(channel_1bit_high, S60.fc, tnrn_up, S60.gama, S60.R0, S60.C, Fs_up, S60.Tp);
                            % 下采样,得上采样RC
                            RC_up = crop_range_doppler_to_width(RC_high, S60.nrn);
                            
                            %% low上采样
                            signal60_patch_low = range_upsample_fft(signal60_input_patch, q_low);
                            % ==================================================================================================
                            % 构造上采样后对应的RD参数 
                            nrn_low = size(signal60_patch_low, 1);
                            Fs_low  = q_low * S60.Fs;
                            Tnrn_low   = 1 / Fs_low;
                            Tstart_low = 2 * S60.R0 / S60.C - nrn_low / 2 / Fs_low;
                            Tend_low   = 2 * S60.R0 / S60.C + (nrn_low / 2 - 1) / Fs_low;
                            tnrn_low   = (Tstart_low : Tnrn_low : Tend_low).';
                            % ==================================================================================================
                            % RT阈值1bit量化
                            channel_1bit_low = quantize_1bit_with_U(signal60_patch_low, U_master_patch(1:q_lcm/q_low:end, :));
                            % RC
                            RC_low  = Range_Compress(channel_1bit_low, S60.fc, tnrn_low, S60.gama, S60.R0, S60.C, Fs_low, S60.Tp);
                            RC_down = crop_range_doppler_to_width(RC_low, S60.nrn);

                            % 拼接q3和q1的RC
                            % 能量对齐
                            [RC_mix, info] = energy_crop(RC_up, RC_down, mode_mask_1200, EDGE_BUFFER);

                            % 低采样率参数下继续成像
                            RCMC_mix = RCMC(RC_mix, S60.lambda, S60.fnrn, S60.fnan, S60.R0, S60.C, S60.v);
                            IMG_mix  = SAR_Imaging(RCMC_mix, S60.lambda, S60.Fs, S60.R0, S60.C, S60.v, S60.tnan, S60.Ta, S60.prf);
                            roi_mix = abs(IMG_mix(S60.nrn/2-S60.R_total/2+1:S60.nrn/2+S60.R_total/2, S60.nan/2-S60.A_num/2:S60.nan/2+S60.A_num/2-1));
                            % max_val = max(roi_mix(:));
                            % min_val = min(roi_mix(:));
                            % fprintf('灰度图最大值: %d, 最小值: %d\n', max_val, min_val);
                            norm_L_mix = single(minmaxnormalize_image(roi_mix, q_low_meta.V_MAX_Q_L, q_low_meta.V_MIN_Q_L));
                            % imagesc(norm_L_mix);axis image;colormap gray;
                            seq_input_L(:,:,k) = crop_center(norm_L_mix,  PATCH_SIZE);
                
                        otherwise
                            error('未知 frame_mode: %s', string(frame_mode));
                    end

                    frame_mode_id(k)       = encode_frame_mode(frame_mode);
                    mode_mask_512_all(k,:) = uint8(mode_mask_512);
                end

                % ========== 命名 ==========
                if split_id == 1
                    save_name_l = sprintf('%s_L_seq_%06d.mat', core_name, global_train_idx);
                    save_path_l = fullfile(TRAIN_L_DIR, save_name_l);
                else
                    save_name_l = sprintf('%s_L_seq_%06d.mat', core_name, global_test_idx);
                    save_path_l = fullfile(TEST_L_DIR, save_name_l);
                end

                % ========== 转 uint8 保存 ==========
                seq_GT_L_u8    = to_uint8_image(seq_GT_L);
                seq_input_L_u8 = to_uint8_image(seq_input_L);

                save_sequence_hdf5( ...
                    save_path_l, ...
                    seq_GT_L_u8, seq_input_L_u8, ...
                    frame_mode_id, mode_mask_512_all, sigma_seq, A_rt);

                if split_id == 1
                    global_train_idx = global_train_idx + 1;
                else
                    global_test_idx = global_test_idx + 1;
                end
            end
        end
    end

    t = toc;
    fprintf("✅ [%s] 处理完毕！耗时: %.2fs\n", ROOT_DIR, t);
end

fprintf('\n🎉 全部完成。\n');


%% =========================================================
%% ==================== 局部函数区 =========================
%% =========================================================

% QUICK_LCM 快速计算两个数（支持整数和小数）的最小公倍数
function val = quick_lcm(a, b)
    % QUICK_LCM 快速计算两个数（兼容整数和任意小数）的最小公倍数
    % 输入: a, b (标量)
    % 输出: val (最小公倍数)
    
    if a == 0 || b == 0
        val = 0;
        return;
    end
    
    % 将浮点数转化为最简分数: a = n1/d1, b = n2/d2
    [n1, d1] = rat(a);
    [n2, d2] = rat(b);
    
    % 分数的 LCM 公式: 分子的 LCM / 分母的 GCD
    % 此时 n1, d1, n2, d2 均为代表整数的 double，符合新版 gcd/lcm 要求
    num_lcm = (abs(n1 * n2)) / gcd(n1, n2);
    den_gcd = gcd(d1, d2);
    
    val = num_lcm / den_gcd;
end

% 获取全局掩膜
function global_mode_mask_512 = build_global_mode_mask_512(logic_len)
    assert(logic_len == 1536, '当前固定逻辑长度应为 1536');
    global_mode_mask_512 = false(1, logic_len);  % false=low, true=high

    % H(768) - L(768) - H(768)
    global_mode_mask_512(1:512)       = true;
    global_mode_mask_512(1024+1:1536)   = true;
end

% 裁剪4000+的整体信号块
function seq_block = extract_sequence_block_60mhz(channel_60, block_start, sig_h, block_len)
    row_end = sig_h;
    col_end = block_start + block_len - 1;

    if size(channel_60, 1) < row_end
        error('extract_sequence_block_60mhz: 行数不足');
    end
    if size(channel_60, 2) < col_end
        error('extract_sequence_block_60mhz: 列数不足');
    end

    seq_block = channel_60(1:row_end, block_start:col_end);
end

% 一次生成全局RT阈值
function [U_master_seq, sigma_seq, A_rt] = build_master_threshold_seq(seq60_input, q, As)
    seq_up = range_upsample_fft(seq60_input, q);   % [q_high*1200 x 2224]
    
    % 上采样后的阈值和没有上采样的阈值是一致的，这里可以统一用sigma_seq
    sigma_seq = sqrt(2 / pi) * mean(abs(seq_up(:)));
    A_rt = As * sigma_seq;

    phi_seq = 2 * pi * rand(size(seq_up, 1), 1);     % 序列级唯一随机相位
    U_master_seq = A_rt * exp(1i * phi_seq);         % [q_high*1200 x 1]
end

% 从整段序列信号中截取一patch的信号（1200，1200）
function [signal60_clean_patch, signal60_input_patch, U_master_patch] = ...
    get_frame_patches(seq60_clean, seq60_input, U_master_seq, k, step, sig_w)

    input_s = 1 + (k - 1) * step;
    input_e = input_s + sig_w - 1;

    signal60_clean_patch = seq60_clean(:, input_s:input_e);
    signal60_input_patch = seq60_input(:, input_s:input_e);

    U_master_patch = U_master_seq;   %
end

% 生成一patch的信号对应的掩码（1200，1200）
function [mode_mask_512, mode_mask_1200, frame_mode] = ...
    get_frame_mode_masks(global_mode_mask_512, k, step, patch_size, sig_w, valid_margin)

    valid_s = 1 + (k - 1) * step;
    valid_e = valid_s + patch_size - 1;

    mode_mask_512 = global_mode_mask_512(valid_s:valid_e);

    mode_mask_1200 = [ ...
        repmat(mode_mask_512(1),   1, valid_margin), ...
        mode_mask_512, ...
        repmat(mode_mask_512(end), 1, valid_margin) ...
    ];

    assert(numel(mode_mask_1200) == sig_w, 'mode_mask_1200 长度必须为 1200');

    if all(mode_mask_512)
        frame_mode = "high";
    elseif all(~mode_mask_512)
        frame_mode = "low";
    else
        frame_mode = "mixed";
    end
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
function S_up = range_upsample_fft(S, q_high)
    [Nr, Na] = size(S);
    Nr_up = q_high * Nr;

    Sf = fftshift(fft(S, [], 1), 1);

    pad_total = Nr_up - Nr;
    pad_top    = floor(pad_total / 2);
    pad_bottom = pad_total - pad_top;

    Sf_up = [zeros(pad_top, Na, 'like', Sf); ...
             Sf; ...
             zeros(pad_bottom, Na, 'like', Sf)];

    S_up = ifft(ifftshift(Sf_up, 1), [], 1) * q_high;
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


% 能量对齐并返回对齐拼接后的RC,要考虑1.不同混合率,2.不同混合方向
function [RC, info] = energy_crop(RC_up, RC_down, mode_mask_1200, buffer)
% ENERGY_CROP
% 根据 mode_mask_1200 自动判断 0/1 区域和边界，
% 将 mask==1 对应的数据 RC_up 能量对齐到 mask==0 对应的数据 RC_down，
% 最后按 mask 拼接输出 RC。
%
% 输入:
%   RC_up          : mask==1 对应的数据, size = [Nr, Na]
%   RC_down         : mask==0 对应的数据, size = [Nr, Na]
%   mode_mask_1200  : 1 x Na 或 Na x 1, 只包含 0 和 1
%   buffer          : 边界两侧用于估计能量的宽度
%
% 输出:
%   RC              : 拼接后的数据
%   info            : 调试信息，包括边界、方向、能量、缩放系数等

    % ---------- 基础检查 ----------
    mode_mask = mode_mask_1200(:).';   % 强制变成行向量

    [Nr1, Na1] = size(RC_up);
    [Nr0, Na0] = size(RC_down);

    if Nr1 ~= Nr0 || Na1 ~= Na0
        error("RC_one 和 RC_zero 尺寸不一致: RC_one=[%d,%d], RC_zero=[%d,%d]", ...
            Nr1, Na1, Nr0, Na0);
    end

    Na = Na1;

    if numel(mode_mask) ~= Na
        error("mode_mask_1200 长度必须等于 RC 的列数。mask长度=%d, RC列数=%d", ...
            numel(mode_mask), Na);
    end

    unique_vals = unique(mode_mask);
    if ~all(ismember(unique_vals, [0, 1]))
        error("mode_mask_1200 只能包含 0 和 1。");
    end

    if nargin < 4 || isempty(buffer)
        buffer = 50;
    end

    % ---------- 找边界 ----------
    % diff ~= 0 的地方就是 0/1 发生跳变的位置
    change_idx = find(diff(mode_mask) ~= 0);

    if isempty(change_idx)
        error("mode_mask_1200 中没有检测到 0/1 边界。");
    end

    if numel(change_idx) > 1
        warning("检测到多个 0/1 边界，将使用第一个边界。change_idx = %s", ...
            mat2str(change_idx));
    end

    K_boundary = change_idx(1);
    left_val  = mode_mask(K_boundary);
    right_val = mode_mask(K_boundary + 1);

    % 例如:
    % 如果 left_val=1, right_val=0，说明左边是 1，右边是 0
    % 如果 left_val=0, right_val=1，说明左边是 0，右边是 1

    % ---------- 边界附近窗口 ----------
    idx_left_edge  = max(1, K_boundary - buffer + 1) : K_boundary;
    idx_right_edge = (K_boundary + 1) : min(Na, K_boundary + buffer);

    if isempty(idx_left_edge) || isempty(idx_right_edge)
        error("边界附近窗口为空，请检查 K_boundary=%d, buffer=%d, Na=%d", ...
            K_boundary, buffer, Na);
    end

    % ---------- 根据边界左右的 mask 值，分别取 1 区域和 0 区域边界能量 ----------
    if left_val == 1 && right_val == 0
        % 左边是 1，右边是 0
        idx_one_edge  = idx_left_edge;
        idx_zero_edge = idx_right_edge;

        direction = "one_left_zero_right";

    elseif left_val == 0 && right_val == 1
        % 左边是 0，右边是 1
        idx_zero_edge = idx_left_edge;
        idx_one_edge  = idx_right_edge;

        direction = "zero_left_one_right";

    else
        error("边界判断异常。left_val=%d, right_val=%d", left_val, right_val);
    end

    % ---------- 计算边界附近能量 ----------
    power_one_edge  = mean(abs(RC_up(:,  idx_one_edge)).^2,  'all');
    power_zero_edge = mean(abs(RC_down(:, idx_zero_edge)).^2, 'all');

    eps_power = 1e-12;

    if power_one_edge < eps_power
        warning("mask==1 边界能量过小，scale_factor 设置为 1。");
        scale_factor = 1;
    else
        % 目标：把 1 的能量对齐到 0
        scale_factor = sqrt((power_zero_edge + eps_power) / (power_one_edge + eps_power));
    end

    RC_one_aligned = RC_up * scale_factor;
    % RC_one_aligned = RC_up * 2/3;

    % ---------- 按 mask 拼接 ----------
    RC = zeros(size(RC_up), 'like', RC_up);

    idx_one_all  = mode_mask == 1;
    idx_zero_all = mode_mask == 0;

    RC(:, idx_one_all)  = RC_one_aligned(:, idx_one_all);
    RC(:, idx_zero_all) = RC_down(:, idx_zero_all);

    % ---------- 输出调试信息 ----------
    info = struct();
    info.K_boundary = K_boundary;
    info.left_val = left_val;
    info.right_val = right_val;
    info.direction = direction;
    info.idx_one_edge = idx_one_edge;
    info.idx_zero_edge = idx_zero_edge;
    info.power_one_edge = power_one_edge;
    info.power_zero_edge = power_zero_edge;
    info.scale_factor = scale_factor;
    info.num_one = sum(idx_one_all);
    info.num_zero = sum(idx_zero_all);
end

% 从600的图片中裁剪512的区域
function patch = crop_center(img, patch_size)
    [h, w] = size(img);
    assert(patch_size <= h && patch_size <= w, 'crop_center: patch_size 超出图像范围');

    r0 = floor((h - patch_size) / 2) + 1;
    c0 = floor((w - patch_size) / 2) + 1;

    patch = img(r0:r0 + patch_size - 1, c0:c0 + patch_size - 1);
end


function out = to_uint8_image(x)
    x = max(0, min(1, x));
    out = uint8(round(x * 255));
end

function id = encode_frame_mode(frame_mode)
    switch string(frame_mode)
        case "low"
            id = uint8(1);
        case "high"
            id = uint8(2);
        case "mixed"
            id = uint8(3);
        case "gt"
            id = uint8(4);
        otherwise
            id = uint8(0);
    end
end

function save_sequence_hdf5( ...
    save_path_l, ...
    seq_GT_L_u8, seq_input_L_u8, ...
    frame_mode_id, mode_mask_512_all, sigma_seq, A_rt)

    chunk_sz = [128, 128, size(seq_GT_L_u8, 3)];
    max_retries = 3;

    success_l = false;
    for retry_idx = 1:max_retries
        try
            if exist(save_path_l, 'file'), delete(save_path_l); end

            h5create(save_path_l, '/seq_GT_L',    size(seq_GT_L_u8),    ...
                'Datatype', 'uint8', 'ChunkSize', chunk_sz, 'Deflate', 5);
            h5create(save_path_l, '/seq_input_L', size(seq_input_L_u8), ...
                'Datatype', 'uint8', 'ChunkSize', chunk_sz, 'Deflate', 5);

            h5create(save_path_l, '/frame_mode_id', size(frame_mode_id), 'Datatype', 'uint8');
            h5create(save_path_l, '/mode_mask_512_all', size(mode_mask_512_all), 'Datatype', 'uint8');
            h5create(save_path_l, '/sigma_seq', 1, 'Datatype', 'single');
            h5create(save_path_l, '/A_rt',      1, 'Datatype', 'single');

            h5write(save_path_l, '/seq_GT_L',    seq_GT_L_u8);
            h5write(save_path_l, '/seq_input_L', seq_input_L_u8);
            h5write(save_path_l, '/frame_mode_id', frame_mode_id);
            h5write(save_path_l, '/mode_mask_512_all', mode_mask_512_all);
            h5write(save_path_l, '/sigma_seq', single(sigma_seq));
            h5write(save_path_l, '/A_rt',      single(A_rt));

            success_l = true;
            break;
        catch ME
            fprintf('  ⚠️ Linear 写入失败 (第 %d 次): %s\n', retry_idx, ME.message);
            pause(2);
        end
    end

    if ~success_l
        error('Linear 文件写入失败: %s', save_path_l);
    end
end
