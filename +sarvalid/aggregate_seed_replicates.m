function output = aggregate_seed_replicates(input, group_names, seed_name)
%AGGREGATE_SEED_REPLICATES 先在样本或序列内部聚合随机seed重复。

arguments
    input table
    group_names (1, :) string
    seed_name (1, 1) string = "SeedFamily"
end
variables = string(input.Properties.VariableNames);
if ~all(ismember([group_names, seed_name], variables))
    error('sarvalid:SeedAggregateSchema', 'seed聚合表缺少分组字段。');
end
numeric_names = strings(0, 1);
for name = setdiff(variables, [group_names, seed_name], 'stable')
    if isnumeric(input.(name)) || islogical(input.(name))
        numeric_names(end+1, 1) = name; %#ok<AGROW>
    end
end

groups = unique(input(:, group_names), 'rows', 'stable');
output = table();
for idx = 1:height(groups)
    mask = true(height(input), 1);
    for name = group_names
        input_values = input.(name);
        group_values = groups.(name);
        mask = mask & input_values == group_values(idx);
    end
    rows = input(mask, :);
    row = groups(idx, :);
    SeedCount = numel(unique(rows.(seed_name)));
    row = addvars(row, SeedCount);
    for name = numeric_names.'
        row.(name) = mean(rows.(name));
        row.(name + "_SeedStd") = std(rows.(name), 0);
    end
    if isempty(output)
        output = row;
    else
        output = [output; row]; %#ok<AGROW>
    end
end
end
