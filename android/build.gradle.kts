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
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
    tasks.withType<JavaCompile>().configureEach {
        // Isolate javac from the Gradle daemon. This avoids a JDK 21 ZipFS file
        // handle race seen on Windows while large WebRTC dependencies are open.
        options.isFork = true
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
