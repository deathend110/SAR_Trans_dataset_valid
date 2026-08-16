function [candidates, limits] = range_sft_v3_grid(cfg, S60, q_high, q_low, anchor)
%RANGE_SFT_V3_GRID 生成V3粗搜索或局部细化的合法2D-SFT网格。

arguments
    cfg (1, 1) struct
    S60 (1, 1) struct
    q_high (1, 1) double {mustBePositive}
    q_low (1, 1) double {mustBePositive}
    anchor = []
end

v3 = cfg.range_2dsft_v3;
threshold = struct("As", cfg.threshold.As, "STR_dB", 0, ...
    "fr_over_Br", 0, "fa_over_Ba", 0, "phi0", cfg.threshold.phi0);
pair = sarvalid.make_pair_config( ...
    cfg, "Range_2D_SFT", q_high, q_low, 1, threshold);
grid_h = sarvalid.resolve_acquisition( ...
    pair.H, [cfg.sequence.signal_height, cfg.sequence.block_width], S60);
grid_l = sarvalid.resolve_acquisition( ...
    pair.L, [cfg.sequence.signal_height, cfg.sequence.block_width], S60);

fr_limit = cfg.threshold.nyquist_margin * ...
    min(grid_h.Fs_up, grid_l.Fs_up) / (2 * S60.B);
Ba = resolve_azimuth_bandwidth(S60);
fa_limit = cfg.threshold.nyquist_margin * ...
    min(grid_h.PRF_up, grid_l.PRF_up) / (2 * Ba);
limits = struct("fr_over_Br", fr_limit, "fa_over_Ba", fa_limit, ...
    "H", compact_grid(grid_h), "L", compact_grid(grid_l));

if isempty(anchor)
    STR_values = unique(double(v3.STR_grid(:).'));
    fr_values = legal_values(v3.fr_grid, fr_limit);
    fa_values = legal_values(v3.fa_grid, fa_limit);
    stage = "coarse";
else
    STR_values = unique(double(anchor.STRdB) + ...
        double(v3.fine_STR_offsets(:).'));
    fr_values = legal_values(double(anchor.FrOverBr) + ...
        double(v3.fine_frequency_offsets(:).'), fr_limit);
    fa_values = legal_values(double(anchor.FaOverBa) + ...
        double(v3.fine_frequency_offsets(:).'), fa_limit);
    stage = "fine";
end

[STR, Fr, Fa] = ndgrid(STR_values, fr_values, fa_values);
row_count = numel(STR);
Stage = repmat(stage, row_count, 1);
QHigh = repmat(q_high, row_count, 1);
QLow = repmat(q_low, row_count, 1);
STRdB = STR(:);
FrOverBr = Fr(:);
FaOverBa = Fa(:);
FrLimit = repmat(fr_limit, row_count, 1);
FaLimit = repmat(fa_limit, row_count, 1);
PairKey = strings(row_count, 1);
for idx = 1:row_count
    candidate_threshold = struct("As", cfg.threshold.As, ...
        "STR_dB", STRdB(idx), "fr_over_Br", FrOverBr(idx), ...
        "fa_over_Ba", FaOverBa(idx), "phi0", cfg.threshold.phi0);
    candidate_pair = sarvalid.make_pair_config( ...
        cfg, "Range_2D_SFT", q_high, q_low, 1, candidate_threshold);
    PairKey(idx) = sarvalid.generator_file_key( ...
        candidate_pair, cfg.threshold_seed);
end
candidates = table(Stage, PairKey, QHigh, QLow, STRdB, ...
    FrOverBr, FaOverBa, FrLimit, FaLimit);
end

function values = legal_values(values, legal_limit)
% 频率必须同时非负、在用户上限内并严格小于H/L共同Nyquist上限。
values = unique(round(double(values(:).'), 10));
values = values(values >= 0 & values <= 4 & values < legal_limit);
if isempty(values)
    error('sarvalid:V3EmptyFrequencyGrid', ...
        'Nyquist裁剪后没有合法的2D-SFT频率候选。');
end
end

function bandwidth = resolve_azimuth_bandwidth(S60)
if isfield(S60, "Ba")
    bandwidth = S60.Ba;
elseif isfield(S60, "Bd")
    bandwidth = S60.Bd;
elseif isfield(S60, "Da")
    bandwidth = 2 * S60.v / S60.Da;
else
    error('sarvalid:MissingAzimuthBandwidth', ...
        '成像参数必须包含Ba、Bd或Da以确定方位带宽。');
end
end

function output = compact_grid(grid)
output = struct("q_total", grid.q_total, ...
    "q_range_eff", grid.q_range_eff, ...
    "q_azimuth_eff", grid.q_azimuth_eff, ...
    "q_total_eff", grid.q_total_eff, ...
    "Fs_up", grid.Fs_up, "PRF_up", grid.PRF_up, ...
    "upsampled_size", grid.upsampled_size);
end
