allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

subprojects {
    afterEvaluate {
        project.extensions.findByType(com.android.build.api.dsl.CommonExtension::class.java)?.apply {
            compileSdk = 36
        }

        if (project.name == "audio_service") {
            project.extensions
                .findByType(com.android.build.api.dsl.LibraryExtension::class.java)
                ?.sourceSets
                ?.getByName("main")
                ?.java
                ?.srcDir(rootProject.file("audio_service_patch/src/main/java"))

            // Replace only AudioService.java; keep the hosted plugin's Dart,
            // resources and remaining Android classes unchanged.
            project.tasks
                .withType(org.gradle.api.tasks.compile.JavaCompile::class.java)
                .configureEach {
                    exclude("com/ryanheise/audioservice/AudioService.java")
                }
        }
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
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
