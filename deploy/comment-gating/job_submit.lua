--[[
  job_submit.lua — Slurm job submit plugin

  Enforces:
    1. --comment=cpx/tpx requires --exclusive
       (rocm-smi --setcomputepartition is a node-wide op).
    2. --comment containing "ollama" (rocBudAI) requires:
         a) --exclusive (node-wide ollama daemon + 4-GPU model)
         b) an MI300A SPX partition (qwen3.5:122b needs full SPX mode
            with OLLAMA_SCHED_SPREAD=1 across 4×32 GB MI300A GPUs)
]]--

-- ===========================================================================
-- SITE CONFIG — the one cluster-specific knob in this file.
--
-- Partitions on which --comment=ollama is permitted. The reference cluster
-- gates rocBudAI onto its full-GPU (SPX) MI300A partition because the default
-- model needs whole GPUs. Replace the entry below with your own partition
-- name(s), add more as needed, OR leave the table EMPTY to disable the
-- partition gate entirely (any partition is then allowed; the --exclusive
-- requirement still applies).
-- ===========================================================================
local OLLAMA_PARTITIONS = {
    ["PPAC_MI300A_SPX"] = true,
}

local function comment_has_ollama(lower_comment)
    if lower_comment == nil then return false end
    for token in string.gmatch(lower_comment, "[^,%s]+") do
        if token == "ollama" then return true end
    end
    return false
end

local function ollama_partition_gate_enabled()
    return next(OLLAMA_PARTITIONS) ~= nil
end

local function partition_allowed_for_ollama(partition)
    -- Empty allow-list = no partition gate (site opted out).
    if not ollama_partition_gate_enabled() then return true end
    if partition == nil or partition == "" then return false end
    for p in string.gmatch(partition, "[^,%s]+") do
        if OLLAMA_PARTITIONS[p] then return true end
    end
    return false
end

local function ollama_partition_list()
    local out = ""
    for p, _ in pairs(OLLAMA_PARTITIONS) do
        if out ~= "" then out = out .. ", " end
        out = out .. p
    end
    return out
end

function slurm_job_submit(job_desc, part_list, submit_uid)

    local comment = job_desc.comment

    if comment == nil then
        return slurm.SUCCESS
    end

    local lower_comment = string.lower(comment)

    -- Rule 1: cpx/tpx GPU-mode comments must be --exclusive.
    if lower_comment == "cpx" or lower_comment == "tpx" then
        if job_desc.shared ~= 0 then
            slurm.log_info("job_submit.lua: Rejecting job from uid %u: "
                .. "--comment=%s requires --exclusive (node-wide GPU mode change)",
                submit_uid, comment)
            slurm.user_msg("Error: --comment=" .. comment
                .. " requires --exclusive because GPU compute partition "
                .. "mode changes affect all GPUs on the node. "
                .. "Please resubmit with --exclusive.")
            return slurm.ERROR
        end

        -- Normalise the comment to lowercase on the job so a case-sensitive
        -- bash `case` in the site prolog/epilog and sacct see canonical
        -- "cpx"/"tpx". Without this, --comment=CPX can silently skip a
        -- rocm-smi --setcomputepartition step that matches only the literal
        -- lowercase form. Normalising here keeps accounting clean.
        if comment ~= lower_comment then
            job_desc.comment = lower_comment
            slurm.log_info("job_submit.lua: Normalising comment '%s' -> '%s' "
                .. "for uid %u (cpx/tpx case-fold)",
                comment, lower_comment, submit_uid)
        end

        slurm.log_info("job_submit.lua: Allowing %s mode for exclusive job from uid %u",
            lower_comment, submit_uid)
    end

    -- Rule 2: --comment=ollama (rocBudAI) needs --exclusive AND SPX partition.
    if comment_has_ollama(lower_comment) then
        if job_desc.shared ~= 0 then
            slurm.log_info("job_submit.lua: Rejecting --comment=ollama job from uid %u: "
                .. "--exclusive required",
                submit_uid)
            slurm.user_msg("Error: --comment=ollama requires --exclusive. "
                .. "The ollama daemon and qwen3.5:122b model use the entire node "
                .. "(all 4 MI300A GPUs in SPX mode). "
                .. "Please resubmit with --exclusive.")
            return slurm.ERROR
        end

        if not partition_allowed_for_ollama(job_desc.partition) then
            local allowed = ollama_partition_list()
            slurm.log_info("job_submit.lua: Rejecting --comment=ollama job from uid %u: "
                .. "partition '%s' is not an ollama-allowed SPX partition",
                submit_uid, job_desc.partition or "<none>")
            slurm.user_msg("Error: --comment=ollama is only allowed on MI300A SPX "
                .. "partitions (qwen3.5:122b requires multiple GPUs in SPX mode). "
                .. "Allowed partitions: " .. allowed
                .. ". Please resubmit with -p <one-of-those>.")
            return slurm.ERROR
        end

        slurm.log_info("job_submit.lua: Allowing --comment=ollama for exclusive job "
            .. "from uid %u on partition '%s'",
            submit_uid, job_desc.partition)
    end

    return slurm.SUCCESS
end

function slurm_job_modify(job_desc, job_rec, part_list, modify_uid)
    return slurm.SUCCESS
end
