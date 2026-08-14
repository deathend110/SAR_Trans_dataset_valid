function candidates = sft_candidate_grid(cfg, method, q_high, q_low, alpha, S60, best)
%SFT_CANDIDATE_GRID 按H/L共同Nyquist约束生成SFT粗筛或细化网格。

arguments
    cfg (1, 1) struct
    method (1, 1) string
    q_high (1, 1) double
    q_low (1, 1) double
    alpha (1, 1) double
    S60 (1, 1) struct
    best = []
end

probe_threshold = struct("As", cfg.threshold.As, "STR_dB", 0, ...
    "fr_over_Br", 0, "fa_over_Ba", 0, "phi0", cfg.threshold.phi0);
pair = sarvalid.make_pair_config(cfg, method, q_high, q_low, alpha, probe_threshold);
grid_h = sarvalid.resolve_acquisition(pair.H, [S60.nrn, S60.nan], S60);
grid_l = sarvalid.resolve_acquisition(pair.L, [S60.nrn, S60.nan], S60);

fr_limit = cfg.threshold.nyquist_margin * ...
    min(grid_h.Fs_up, grid_l.Fs_up) / (2 * S60.B);
Ba = resolve_azimuth_bandwidth(S60);
fa_limit = cfg.threshold.nyquist_margin * ...
    min(grid_h.PRF_up, grid_l.PRF_up) / (2 * Ba);

if isempty(best)
    STR_values = cfg.threshold.STR_coarse_dB;
    if startsWith(method, "Range_")
        fr_values = bounded_grid(cfg.threshold.range_frequency_step, ...
            fr_limit, cfg.threshold.frequency_cap);
        fa_values = 0;
    else
        fr_values = bounded_grid(cfg.threshold.baru_frequency_step, ...
            fr_limit, cfg.threshold.frequency_cap);
        fa_values = bounded_grid(cfg.threshold.baru_frequency_step, ...
            fa_limit, cfg.threshold.frequency_cap);
    end
    stage = "coarse";
else
    STR_values = unique(best.STRdB + cfg.threshold.fine_STR_offsets_dB);
    fr_values = bounded_values(best.FrOverBr + ...
        cfg.threshold.fine_frequency_offsets, fr_limit);
    if startsWith(method, "Range_")
        fa_values = 0;
    else
        fa_values = bounded_values(best.FaOverBa + ...
            cfg.threshold.fine_frequency_offsets, fa_limit);
    end
    stage = "fine";
end

[STR, Fr, Fa] = ndgrid(STR_values, fr_values, fa_values);
row_count = numel(STR);
Stage = repmat(stage, row_count, 1);
Alpha = repmat(alpha, row_count, 1);
STRdB = STR(:);
FrOverBr = Fr(:);
FaOverBa = Fa(:);
FrLimit = repmat(fr_limit, row_count, 1);
FaLimit = repmat(fa_limit, row_count, 1);
candidates = table(Stage, Alpha, STRdB, FrOverBr, FaOverBa, FrLimit, FaLimit);
end

function values = bounded_grid(step, legal_limit, cap)
upper = min(legal_limit, cap);
last = floor((upper - 1e-12) / step) * step;
values = 0:step:max(0, last);
end

function values = bounded_values(values, legal_limit)
values = unique(round(values(:).', 10));
values = values(values >= 0 & values < legal_limit);
if isempty(values)
    values = 0;
end
end

function bandwidth = resolve_azimuth_bandwidth(S60)
if isfield(S60, "Ba")
    bandwidth = S60.Ba;
elseif isfield(S60, "Bd")
    bandwidth = S60.Bd;
else
    bandwidth = 2 * S60.v / S60.Da;
end
end
