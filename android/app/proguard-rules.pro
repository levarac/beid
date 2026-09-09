# App-specific R8 rules belong here. There are currently no app-specific keep
# rules: the app and shared module use kotlinx.serialization's JsonElement tree
# API directly, not reflection or generated @Serializable serializers. Android
# manifest entry points and dependency consumer rules are handled by the Android
# Gradle plugin and R8's merged default configuration.
