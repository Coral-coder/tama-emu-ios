allprojects {
    repositories {
        google()
        mavenCentral()
        // usb-serial-for-android (mik3y) is published on JitPack
        maven { url = uri("https://jitpack.io") }
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
// Some plugins (flutter_blue_plus 1.x) still compile against an old Android API level, which the
// current AndroidX libraries refuse: compile every library module against the app's level.
subprojects {
    val fix = {
        extensions.findByType(com.android.build.api.dsl.LibraryExtension::class.java)?.let { ext ->
            if ((ext.compileSdk ?: 0) < 37) ext.compileSdk = 37
        }
    }
    if (state.executed) fix() else afterEvaluate { fix() }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
