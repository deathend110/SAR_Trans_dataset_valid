function pair_cfg = make_pair_config(cfg, method, q_high, q_low, alpha, threshold)
%MAKE_PAIR_CONFIG 构造共享BARU分配和阈值参数的H/L配置。

arguments
    cfg (1, 1) struct
    method (1, 1) string
    q_high (1, 1) double {mustBePositive}
    q_low (1, 1) double {mustBePositive}
    alpha (1, 1) double = NaN
    threshold (1, 1) struct = struct()
end

if startsWith(method, "BARU_") && ~isfinite(alpha)
    error('sarvalid:MissingBARUAlpha', 'BARU方法必须提供alpha。');
end
if startsWith(method, "Range_")
    alpha = 1;
end

if isempty(fieldnames(threshold))
    threshold = struct("As", cfg.threshold.As, "STR_dB", 0, ...
        "fr_over_Br", 0, "fa_over_Ba", 0, "phi0", cfg.threshold.phi0);
end

base = struct("method", method, "alpha", alpha, ...
    "seed", cfg.threshold_seed, "threshold", threshold, ...
    "time_origin", "block_global", ...
    "share_policy", "same_seed_independent_grid");
H = base;
L = base;
H.q_total = q_high;
L.q_total = q_low;

pair_cfg = struct();
pair_cfg.method = method;
pair_cfg.q_high = q_high;
pair_cfg.q_low = q_low;
pair_cfg.alpha = alpha;
pair_cfg.H = H;
pair_cfg.L = L;
pair_cfg.sequence = cfg.sequence;
pair_cfg.file_key = pair_key(method, q_high, q_low, alpha, threshold);
end

function key = pair_key(method, q_high, q_low, alpha, threshold)
base_h = sarvalid.stable_file_key(method, q_high, alpha);
base_l = sarvalid.stable_file_key(method, q_low, alpha);
key = base_h + "__" + erase(base_l, lower(regexprep(char(method), ...
    '[^A-Za-z0-9]+', '_')) + "_");
if endsWith(method, "_SFT")
    key = key + "_s" + encode(threshold.STR_dB) + ...
        "_fr" + encode(threshold.fr_over_Br) + ...
        "_fa" + encode(threshold.fa_over_Ba);
end
end

function output = encode(value)
output = string(sprintf('%.10g', value));
output = replace(output, "-", "m");
output = replace(output, ".", "p");
end
