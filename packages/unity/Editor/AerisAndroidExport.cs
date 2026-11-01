using System;
using System.IO;

namespace Aeris.Editor
{
/// 纯文件导出步骤可由独立 .NET 测试运行，不加载 UnityEditor。
public static class AerisAndroidExport
{
    const string Marker = "// Aeris Unity Android consumer rules";
    public static void Configure(string unityLibrary, string packageRoot)
    {
        string gradle = Path.Combine(unityLibrary, "build.gradle");
        if (!File.Exists(gradle)) throw new InvalidOperationException("Expected UnityLibrary build.gradle");
        string source = Path.Combine(packageRoot, "Plugins/Android/com/aeris/unity/AerisUnityChannel.java");
        if (!File.Exists(source)) throw new InvalidOperationException("Aeris Android Java plugin missing");
        string target = Path.Combine(unityLibrary, "src/main/java/com/aeris/unity/AerisUnityChannel.java");
        Directory.CreateDirectory(Path.GetDirectoryName(target));
        File.Copy(source, target, true);
        File.WriteAllText(Path.Combine(unityLibrary, "aeris-unity-consumer.pro"),
            "-keep class com.aeris.unity.AerisUnityChannel { public *; }\n" +
            "-keep class com.aeris.unity.AerisUnityChannel$* { *; }\n");
        string text = File.ReadAllText(gradle);
        if (!text.Contains(Marker))
            File.AppendAllText(gradle, "\n" + Marker + "\nandroid { defaultConfig { consumerProguardFiles 'aeris-unity-consumer.pro' } }\n");
    }
}
}
