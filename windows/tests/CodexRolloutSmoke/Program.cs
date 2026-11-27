if (args is ["--status"])
{
    CodexRolloutStatusTests.Run();
    return;
}
QuotaChronologyTests.Run();
CodexRolloutStatusTests.Run();
