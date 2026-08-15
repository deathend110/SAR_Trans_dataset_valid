function key = generator_file_key(pair, seed_families)
%GENERATOR_FILE_KEY 为生成器候选构造包含全部可变参数的稳定文件键。

if nargin < 2
    seed_families = [];
end

method = lower(regexprep(char(string(pair.method)), '[^A-Za-z0-9]+', '_'));
key = string(method) + "_qh" + encode(pair.q_high) + ...
    "_ql" + encode(pair.q_low);
if startsWith(string(pair.method), "BARU_")
    key = key + "_a" + encode(pair.alpha) + ...
        "_as" + encode(pair.H.threshold.As);
else
    key = key + "_s" + encode(pair.H.threshold.STR_dB) + ...
        "_fr" + encode(pair.H.threshold.fr_over_Br) + ...
        "_fa" + encode(pair.H.threshold.fa_over_Ba);
end
if ~isempty(seed_families)
    seed_parts = strings(1, numel(seed_families));
    for idx = 1:numel(seed_families)
        seed_parts(idx) = encode(seed_families(idx));
    end
    key = key + "_sf" + strjoin(seed_parts, "_");
end
end

function value = encode(number)
value = string(sprintf('%.12g', number));
value = replace(value, "-", "m");
value = replace(value, ".", "p");
value = replace(value, "+", "");
end
