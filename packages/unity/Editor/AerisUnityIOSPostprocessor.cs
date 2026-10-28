#if UNITY_EDITOR && UNITY_IOS
using System;
using System.IO;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Callbacks;
using UnityEditor.iOS.Xcode;
using PackageInfo = UnityEditor.PackageManager.PackageInfo;

namespace Aeris.Editor
{
/// 将物理通道编译进 UnityFramework，App 只消费其预编译产物。
public static class AerisUnityIOSPostprocessor
{
    static readonly string[] NativeFiles = { "AerisUnityChannel.h", "AerisUnityHost.h",
                                             "AerisUnityPlugin.h", "AerisUnityPlugin.mm" };

    [PostProcessBuild(1000)]
    public static void OnPostprocessBuild(BuildTarget target, string buildPath)
    {
        if (target != BuildTarget.iOS)
            return;

        PackageInfo package =
            PackageInfo.FindForAssembly(typeof(AerisUnityIOSPostprocessor).Assembly);

        if (package == null)
            throw new BuildFailedException("找不到 Aeris UPM 包，请通过 Package Manager 安装");

        Configure(buildPath, package.resolvedPath);
    }

    // 仅解析工程内这三个已知设置；外部 xcconfig/命令行的策略仍由宿主维护。
    static string EffectiveSetting(PBXProject project, string config, string root, string key)
    {
        string parent = (project.GetBuildPropertyForConfig(root, key) ?? "")
                            .Replace("$(inherited)", "")
                            .Replace("${inherited}", "");
        string value = project.GetBuildPropertyForConfig(config, key);
        // 未定义会继承；显式空值会覆盖，不能把两者当成同一种情况。
        return value == null
                   ? parent
                   : value.Replace("$(inherited)", parent).Replace("${inherited}", parent);
    }

    static bool HasExportFilter(PBXProject project, string config, string root)
    {
        string flags = EffectiveSetting(project, config, root, "OTHER_LDFLAGS");
        string frameworkFlags = EffectiveSetting(project, config, root, "OTHER_LDFLAGS_FRAMEWORK");
        flags = flags.Replace("$(OTHER_LDFLAGS_FRAMEWORK)", frameworkFlags)
                    .Replace("${OTHER_LDFLAGS_FRAMEWORK}", frameworkFlags);
        string file = EffectiveSetting(project, config, root, "EXPORTED_SYMBOLS_FILE");
        return flags.Contains("-exported_symbol") || !string.IsNullOrWhiteSpace(file);
    }

    // 单独入口供导出回归使用；生产回调始终从已安装包解析真实路径。
    public static void Configure(string buildPath, string packagePath)
    {
        string projectPath = PBXProject.GetPBXProjectPath(buildPath);
        string umbrella = Path.Combine(buildPath, "UnityFramework", "UnityFramework.h");
        string sourceRoot = Path.Combine(packagePath, "Plugins", "iOS");

        // 修改工程前先检查全部输入，失败时给出明确的构建错误。
        if (!File.Exists(umbrella))
            throw new BuildFailedException("缺少 UnityFramework 公开 umbrella header");

        foreach (string name in NativeFiles)
        {
            if (!File.Exists(Path.Combine(sourceRoot, name)))
                throw new BuildFailedException("Aeris 原生文件缺失：" + name);
        }

        var project = new PBXProject();
        project.ReadFromFile(projectPath);
        string framework = project.GetUnityFrameworkTargetGuid();

        if (string.IsNullOrEmpty(framework))
            throw new BuildFailedException("导出的工程中没有 UnityFramework target");

        if (string.IsNullOrEmpty(project.GetHeadersBuildPhaseByTarget(framework)))
            project.AddHeadersBuildPhase(framework);

        // 部分 Unity 版本仍会自动导出 UPM 的 Plugins/iOS 源文件。
        // 只撤销 Aeris 包自动副本的编译归属，保留下面带明确参数的唯一副本。
        string automaticSource = project.FindFileGuidByProjectPath(
            "Libraries/com.company.aeris/Plugins/iOS/AerisUnityPlugin.mm");
        if (!string.IsNullOrEmpty(automaticSource))
        {
            project.RemoveFileFromBuild(framework, automaticSource);
            string launcher = project.GetUnityMainTargetGuid();
            if (!string.IsNullOrEmpty(launcher))
                project.RemoveFileFromBuild(launcher, automaticSource);
        }

        string destination = Path.Combine(buildPath, "Libraries", "AerisUnity");
        Directory.CreateDirectory(destination);

        foreach (string name in NativeFiles)
        {
            File.Copy(Path.Combine(sourceRoot, name), Path.Combine(destination, name), true);
            string relative = "Libraries/AerisUnity/" + name;
            string file = project.FindFileGuidByProjectPath(relative);

            if (string.IsNullOrEmpty(file))
                file = project.AddFile(relative, relative, PBXSourceTree.Source);

            // 公开头 API 会复用既有记录，不能先删除其构建对象而留下 Headers 引用。
            if (name.EndsWith(".h", StringComparison.Ordinal))
                project.AddPublicHeaderToBuild(framework, file);
            else
            {
                project.RemoveFileFromBuild(framework, file);
                // Unity 默认关闭 Objective-C 异常；仅为使用 @try 的通道源文件开启。
                project.AddFileToBuildWithFlags(framework, file,
                                                "-fobjc-arc -fobjc-exceptions -std=c++17");
            }
        }

        // 仅补充已有白名单的配置；无白名单时添加 exported_symbol 反而会隐藏 Unity 公共符号。
        foreach (string name in project.BuildConfigNames())
        {
            string config = project.BuildConfigByName(framework, name);
            string root = project.BuildConfigByName(project.ProjectGuid(), name);
            if (!HasExportFilter(project, config, root))
                continue;
            if (project.GetBuildPropertyForConfig(config, "OTHER_LDFLAGS") == null)
                project.SetBuildPropertyForConfig(config, "OTHER_LDFLAGS", "$(inherited)");
            foreach (string symbol in new[] { "_AerisUnity*", "_OBJC_CLASS_$_AerisUnity*",
                                              "_OBJC_METACLASS_$_AerisUnity*" })
                project.AddBuildPropertyForConfig(config, "OTHER_LDFLAGS",
                                                  "-Wl,-exported_symbol," + symbol);
        }

        project.AddFrameworkToProject(framework, "Foundation.framework", false);
        project.WriteToFile(projectPath);

        const string declaration = "#import <UnityFramework/AerisUnityPlugin.h>";
        string header = File.ReadAllText(umbrella);

        if (!header.Contains(declaration))
            File.WriteAllText(umbrella, header.TrimEnd() + "\n\n" + declaration + "\n");
    }
}
}
#endif
