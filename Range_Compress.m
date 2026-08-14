function Range_Com_tr_ta=Range_Compress(echo,fc,tnrn,gama,R0,c,Fs,Tp) %#ok<INUSD>
[nrn,nan]=size(echo);
x=(echo);%.*(exp(-1i*2*pi*fc*tnrn).*ones(1,nan));

% 非整数倍率上采样后，距离维长度和脉冲采样数都可能是奇数。
% 使用整数中心窗口可保持历史偶数网格结果，同时避免半整数索引。
tnrn = tnrn(:);
if numel(tnrn) ~= nrn
    error('Range_Compress:TimeAxisSizeMismatch', ...
        'tnrn长度必须与回波距离维一致。tnrn=%d, nrn=%d', numel(tnrn), nrn);
end

pulse_samples = max(1, fix(Tp * Fs));
center_idx = floor(nrn / 2) + 1;
start_idx = center_idx - floor(pulse_samples / 2);
end_idx = start_idx + pulse_samples - 1;
if start_idx < 1 || end_idx > nrn
    error('Range_Compress:PulseWindowOutOfRange', ...
        '距离匹配滤波窗口超出回波范围。start=%d, end=%d, nrn=%d', ...
        start_idx, end_idx, nrn);
end

Hr=zeros(nrn,nan,'like',echo);
Hrr=exp(1i*pi*gama*(tnrn(start_idx:end_idx)-2*R0/c).^2)*ones(1,nan,'like',echo);
Hr(start_idx:end_idx,:)=Hrr;
Comp_fr_ta=fftshift(fft(fftshift(x,1),[],1),1).*conj(fftshift(fft(fftshift(Hr,1),[],1),1));
Range_Com_tr_ta=fftshift(ifft(fftshift(Comp_fr_ta,1),[],1),1);
