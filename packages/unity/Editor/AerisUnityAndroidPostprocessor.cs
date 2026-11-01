#if UNITY_EDITOR && UNITY_ANDROID
using UnityEditor.Android;
using UnityEditor.Build;
using PackageInfo = UnityEditor.PackageManager.PackageInfo;

namespace Aeris.Editor
{
/// 只向 UnityLibrary 加入同源通用 Java 类，不链接项目 SDK 或宿主 AAR。
public sealed class AerisUnityAndroidPostprocessor : IPostGenerateGradleAndroidProject
{
    public int callbackOrder { get { return 1000; } }
    public void OnPostGenerateGradleAndroidProject(string path)
    {
        var package = PackageInfo.FindForAssembly(typeof(AerisUnityAndroidPostprocessor).Assembly);
        if (package == null) throw new BuildFailedException("找不到 Aeris UPM 包，请通过 Package Manager 安装");
        AerisAndroidExport.Configure(path, package.resolvedPath);
    }
}
}
#endif
