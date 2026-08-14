function S1 = quantize_with_threshold(S, U)
%QUANTIZE_WITH_THRESHOLD 对复回波I/Q分别执行加阈值1-bit判决。

if ~isequal(size(S), size(U))
    error('sarvalid:ThresholdSizeMismatch', ...
        '信号与阈值尺寸不一致：S=%s, U=%s。', mat2str(size(S)), mat2str(size(U)));
end

re = ones(size(S), 'like', real(S));
im = ones(size(S), 'like', real(S));
re(real(S) + real(U) < 0) = -1;
im(imag(S) + imag(U) < 0) = -1;
S1 = complex(re, im);
end
