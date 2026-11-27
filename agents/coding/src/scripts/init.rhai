vars::set_scoped("glob_ignored", args.glob_ignored, "visible", "persisted", ["client"]);
if args.agent_docs.len() > 0 {
    try {
        refs::mount_host(args.agent_docs);
    } catch (err) {}
}
