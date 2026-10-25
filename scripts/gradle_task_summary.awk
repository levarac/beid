# Stream Gradle's plain console without hiding diagnostics. A task can print
# more than one header as parallel output resumes; keep only its last outcome.
{
    print
    fflush()
}
/^> Task :/ {
    outcomes[$3] = (NF == 3 ? "EXECUTED" : $4)
}
END {
    for (task in outcomes) {
        counts[outcomes[task]]++
    }
    printf "Gradle tasks: FROM-CACHE=%d UP-TO-DATE=%d EXECUTED=%d SKIPPED=%d NO-SOURCE=%d FAILED=%d\n", \
        counts["FROM-CACHE"], counts["UP-TO-DATE"], counts["EXECUTED"], \
        counts["SKIPPED"], counts["NO-SOURCE"], counts["FAILED"]
}
