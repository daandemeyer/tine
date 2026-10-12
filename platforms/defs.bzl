# SPDX-FileCopyrightText: Amutable GmbH <https://amutable.com/>
# SPDX-License-Identifier: MPL-2.0

"""tine's platforms: where actions run, and which architecture they build for.

The execution platform is local, optionally against a shared cache. A target platform names constraints
and registers no executor: every action still runs on the local machine, so executed build tools have to
be reached as `exec_dep`. They cannot execute target platform code.
"""

load("@prelude//cfg/exec_platform:marker.bzl", "get_exec_platform_marker")
load(":architecture.bzl", "ARCHITECTURES", "architecture")

def _check_unmarked(platform: PlatformInfo, refs: struct) -> None:
    # Buck keeps the exec mark through a transition. If an execution platform registers the exec marker
    # constraint, an exec caller reaches a second configured target. The two configured targets then
    # download the same files at the same time.
    if refs.exec_marker[ConstraintValueInfo].setting.label in platform.configuration.constraints:
        fail("{} contains the exec marker constraint; register no exec_marker_constraint on the execution platform".format(platform.label))

def _architecture_transition_impl(platform: PlatformInfo, refs: struct) -> PlatformInfo:
    _check_unmarked(platform, refs)
    setting = refs.cpu[ConstraintSettingInfo].label
    cpu = platform.configuration.constraints.get(setting)
    for name in ARCHITECTURES:
        target = getattr(refs, name)[PlatformInfo]
        if cpu != None and target.configuration.constraints[setting].label == cpu.label:
            return target
    fail("{} configures none of the architectures {}".format(platform.label, sorted(ARCHITECTURES)))

# A rule that sets this as its `cfg` is configured for the target platform of the caller's architecture.
# All callers of one architecture then reach the same configured target, whatever else their
# configurations contain.
architecture_transition = transition(
    impl = _architecture_transition_impl,
    refs = {name: "tine//platforms:" + name for name in ARCHITECTURES} | {"cpu": "config//cpu/constraints:cpu", "exec_marker": get_exec_platform_marker()},
)

def _execution_transition_impl(platform: PlatformInfo, refs: struct) -> PlatformInfo:
    _check_unmarked(platform, refs)
    for name in ARCHITECTURES:
        if getattr(refs, "can_execute_" + name)[ConstraintValueInfo].setting.label in platform.configuration.constraints:
            return platform
    return refs.host[PlatformInfo]

# A rule that sets this as its `cfg` is configured for the execution platform an `exec_dep` reaches it
# from. Only an execution platform has a capability constraint, so the transition recognizes an execution
# configuration by it. Every other caller, such as a plain dependency or the command line, reaches the
# target configured for the host's execution platform.
execution_transition = transition(
    impl = _execution_transition_impl,
    refs = {"can_execute_" + name: "tine//platforms:can-execute-" + name for name in ARCHITECTURES}
    | {
        "exec_marker": get_exec_platform_marker(),
        "host": "tine//platforms:exec-" + architecture.host(),
    },
)

def _target_platform_impl(ctx: AnalysisContext) -> list[Provider]:
    constraints = dict()
    for configuration in ctx.attrs.configurations:
        constraints.update(configuration[ConfigurationInfo].constraints)

    # A target that has to be built for one architecture whatever asked for it takes this as its
    # incoming transition, rather than the whole build being pointed at the platform.
    def select_platform(platform: PlatformInfo) -> PlatformInfo:
        return PlatformInfo(
            label = platform.label,
            configuration = ConfigurationInfo(
                constraints = platform.configuration.constraints | constraints,
                values = platform.configuration.values,
            ),
        )

    return [
        DefaultInfo(),
        PlatformInfo(
            label = str(ctx.label.raw_target()),
            configuration = ConfigurationInfo(constraints = constraints, values = {}),
        ),
        TransitionInfo(impl = select_platform),
    ]

target_platform = rule(
    impl = _target_platform_impl,
    attrs = {
        "configurations": attrs.list(attrs.dep(providers = [ConfigurationInfo])),
    },
    is_configuration_rule = True,
)

def _cache_configured() -> bool:
    """Whether `[buck2_re_client]` names a cache to talk to.

    `address` is buck's own fallback for `{engine,action_cache,cas}_address`, and `engine_address` is
    the one buck reaches first, for its capabilities query.
    """
    for key in ("address", "engine_address"):
        if read_root_config("buck2_re_client", key) != None:
            return True
    return False

def _execution_platform_impl(ctx: AnalysisContext) -> list[Provider]:
    constraints = dict()
    constraints.update(ctx.attrs.cpu_configuration[ConfigurationInfo].constraints)
    constraints.update(ctx.attrs.os_configuration[ConfigurationInfo].constraints)
    capability = ctx.attrs.capability[ConstraintValueInfo]
    constraints[capability.setting.label] = capability
    cfg = ConfigurationInfo(constraints = constraints, values = {})

    name = ctx.label.raw_target()
    platform = ExecutionPlatformInfo(
        label = name,
        configuration = cfg,
        executor_config = CommandExecutorConfig(
            # Actions run here, never on a remote worker: the sandbox unshares and mounts, and a VM test
            # wants the host's /dev/kvm. Only the cache is shared.
            local_enabled = True,
            remote_enabled = False,
            remote_cache_enabled = ctx.attrs.remote_cache_enabled,
            # only a cache that takes uploads, and then only for actions that opt in
            allow_cache_uploads = ctx.attrs.allow_cache_uploads,
            # guard against uploading unexpectedly large files; not policy (action's `allow_cache_upload` is)
            # needs to fit the biggest package/compiler output; we don't generally remote-cache image builds
            max_cache_upload_mebibytes = 10240,
        ),
    )

    return [DefaultInfo(), platform, PlatformInfo(label = str(name), configuration = cfg)]

_execution_platform = rule(
    impl = _execution_platform_impl,
    attrs = {
        "allow_cache_uploads": attrs.bool(),
        "capability": attrs.dep(providers = [ConstraintValueInfo], doc = "the binaries the platform's actions can run"),
        "cpu_configuration": attrs.dep(providers = [ConfigurationInfo]),
        "os_configuration": attrs.dep(providers = [ConfigurationInfo]),
        "remote_cache_enabled": attrs.bool(),
    },
)

def execution_platform(name: str, **kwargs) -> None:
    """Register the platform, reading the cache switches here rather than taking them from the caller.

    Buck refuses to build at all once an executor enables `remote_cache_enabled` without configuring
    one. So the cache decision happens via `[buck2_re_client]` config presence.
    """
    _execution_platform(name = name, allow_cache_uploads = read_root_config("tine", "cache-uploads") == "true", remote_cache_enabled = _cache_configured(), **kwargs)

def _execution_platforms_impl(ctx: AnalysisContext) -> list[Provider]:
    constraints = dict()
    constraints.update(ctx.attrs.cpu_configuration[ConfigurationInfo].constraints)
    constraints.update(ctx.attrs.os_configuration[ConfigurationInfo].constraints)
    return [
        DefaultInfo(),
        # This is the default target platform. It has the host's architecture and no capability, so the
        # execution transition never mistakes a target configuration for an execution configuration.
        PlatformInfo(label = str(ctx.label.raw_target()), configuration = ConfigurationInfo(constraints = constraints, values = {})),
        # The prelude's platform also registers an exec marker constraint. Buck then marks every execution
        # configuration, and a transition keeps that mark. A box or a repository would then be configured
        # once more for its exec callers.
        ExecutionPlatformRegistrationInfo(platforms = [platform[ExecutionPlatformInfo] for platform in ctx.attrs.platforms]),
    ]

execution_platforms = rule(
    impl = _execution_platforms_impl,
    attrs = {
        "cpu_configuration": attrs.dep(providers = [ConfigurationInfo]),
        "os_configuration": attrs.dep(providers = [ConfigurationInfo]),
        "platforms": attrs.list(attrs.dep(providers = [ExecutionPlatformInfo]), doc = "the execution platforms, the preferred one first"),
    },
)
