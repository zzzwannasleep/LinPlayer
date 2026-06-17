allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    // 仅当子项目与构建目录位于同一盘符时才重定向构建目录。
    // 否则在 Windows 上（pub 缓存在 C: 盘、构建目录在 D: 盘），AGP 的
    // generateXxxUnitTestConfig 任务会因跨盘符无法计算相对路径而崩溃：
    // "this and base files have different roots"。
    // :app 在 D: 盘照常重定向（Flutter 工具链需在 build/app/outputs 取产物），
    // C: 盘的第三方插件保持默认 build 位置（源码与 build 同盘）。
    if (project.projectDir.toPath().root == newBuildDir.asFile.toPath().root) {
        val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
        project.layout.buildDirectory.value(newSubprojectBuildDir)
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
