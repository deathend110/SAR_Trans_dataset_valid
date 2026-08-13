function signal_Noisy = gaussian(signal, factor)
    % 假设 Echo_Sim 是你的模拟回波数据 (复数矩阵)
    % 1. 获取信号幅度的标准差 sigma
    % 如果你已经知道 sigma 的具体数值，直接赋值即可；
    % 如果不知道，可以用下面这行统计出来：
    sigma = std(abs(signal(:))); 
    
    % 2. 设定目标噪声的标准差
    target_noise_std = factor * sigma;
    
    % 3. 设置噪声均值 (必须为0)
    mu_noise = 0; 
    
    % 4. 生成复高斯白噪声
    [rows, cols] = size(signal);
    
    % 这里的关键是除以 sqrt(2)
    % 因为 randn 生成的数据标准差是 1，方差是 1
    % 我们需要让 实部方差 + 虚部方差 = target_noise_std^2
    scale_factor = target_noise_std / sqrt(2);
    
    % 生成噪声：均值为0，总标准差为 1.4*sigma
    Noise = scale_factor * (randn(rows, cols) + 1j * randn(rows, cols));
    Noise = Noise - mean(Noise, "all");
    
    % 5. 叠加噪声
    signal_Noisy = signal + Noise;
    
    % --- 验证环节 (可选) ---
    % 验证噪声的均值是否接近 0
    % disp(['噪声均值: ', num2str(mean(Noise(:)))]); 
    % 验证噪声的标准差是否接近 1.4*sigma
    % disp(['噪声目标标准差: ', num2str(target_noise_std)]);
    % disp(['噪声实际标准差: ', num2str(std(Noise(:)))]);
    % disp(['噪声实际标准差倍数: ', num2str(std(Noise(:)) / sigma)]);
end
