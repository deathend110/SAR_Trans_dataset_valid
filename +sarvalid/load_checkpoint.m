function state = load_checkpoint(file_path, signature, initial_state)
%LOAD_CHECKPOINT 仅在完整签名一致时恢复checkpoint。

arguments
    file_path (1, 1) string
    signature (1, 1) struct
    initial_state (1, 1) struct
end
state = initial_state;
state.signature = signature;
if ~isfile(file_path)
    return;
end
loaded = load(file_path, 'state');
if ~isfield(loaded, 'state') || ~isfield(loaded.state, 'signature')
    error('sarvalid:CheckpointSchema', 'checkpoint缺少state.signature：%s', file_path);
end
if ~isequaln(loaded.state.signature, signature)
    error('sarvalid:CheckpointSignatureMismatch', ...
        'checkpoint与当前配置不一致：%s', file_path);
end
state = loaded.state;
end
