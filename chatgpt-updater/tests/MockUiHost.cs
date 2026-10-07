using System;
using System.Collections.ObjectModel;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text;

internal static class MockUiHost
{
    private const string ProductionScriptPath = "@@PRODUCTION_SCRIPT@@";
    private const string DemoResult = "@@DEMO_RESULT@@";
    private const int TimeoutSeconds = @@TIMEOUT_SECONDS@@;
    private const string OutputPath = "@@OUTPUT_PATH@@";
    private const string ErrorPath = "@@ERROR_PATH@@";
    private const string SummaryPath = "@@SUMMARY_PATH@@";
    private const string AutomationAssemblyPath = "@@AUTOMATION_ASSEMBLY@@";

    private static string QuotePowerShell(string value)
    {
        return "'" + (value ?? String.Empty).Replace("'", "''") + "'";
    }

    private static void AppendOutput(StringBuilder target, Collection<PSObject> output)
    {
        if (output == null) return;
        foreach (PSObject item in output)
        {
            target.AppendLine(item == null ? String.Empty : item.ToString());
        }
    }

    private static void AppendErrors(StringBuilder target, PSDataStreams streams)
    {
        if (streams == null) return;
        foreach (ErrorRecord error in streams.Error)
        {
            target.AppendLine(error == null ? String.Empty : error.ToString());
        }
    }

    private static void WriteEvidence(string path, string text)
    {
        File.WriteAllText(path, text ?? String.Empty, new UTF8Encoding(false));
    }

    private static int RunProductionPrompt(StringBuilder output, StringBuilder errors)
    {
        InitialSessionState state = InitialSessionState.CreateDefault();
        state.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;

        using (Runspace runspace = RunspaceFactory.CreateRunspace(state))
        {
            runspace.ApartmentState = System.Threading.ApartmentState.STA;
            runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
            runspace.Open();

            using (PowerShell powershell = PowerShell.Create())
            {
                powershell.Runspace = runspace;
                string script =
                    ". " + QuotePowerShell(ProductionScriptPath) +
                    " -Demo -DemoResult " + QuotePowerShell(DemoResult) +
                    " -TimeoutSeconds " + TimeoutSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture) +
                    Environment.NewLine +
                    "Invoke-UbConfirmationPrompt -StateRoot $UbCliRoot -Key $UbCliExpectedKey -Version $UbCliExpectedVersion" +
                    " -DemoMode -MockResult " + QuotePowerShell(DemoResult) +
                    " -PromptTimeoutSeconds " + TimeoutSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture);

                Collection<PSObject> result = powershell.AddScript(script).Invoke();
                AppendOutput(output, result);
                AppendErrors(errors, powershell.Streams);
                if (powershell.InvocationStateInfo.State == PSInvocationState.Failed || powershell.Streams.Error.Count > 0)
                {
                    return 1;
                }
                return 0;
            }
        }
    }

    private static int Run()
    {
        StringBuilder output = new StringBuilder();
        StringBuilder errors = new StringBuilder();
        int exitCode = 1;
        try
        {
            exitCode = RunProductionPrompt(output, errors);
        }
        catch (Exception exception)
        {
            errors.AppendLine(exception.ToString());
            exitCode = 1;
        }

        WriteEvidence(OutputPath, output.ToString());
        WriteEvidence(ErrorPath, errors.ToString());
        WriteEvidence(
            SummaryPath,
            "DemoResult=" + DemoResult + Environment.NewLine +
            "TimeoutSeconds=" + TimeoutSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture) + Environment.NewLine +
            "ExitCode=" + exitCode.ToString(System.Globalization.CultureInfo.InvariantCulture) + Environment.NewLine +
            "ProductionScript=" + ProductionScriptPath + Environment.NewLine +
            "MockBoundary=Invoke-UbConfirmationPrompt DemoMode; no OpenApp parameter" + Environment.NewLine +
            "OutputFile=" + OutputPath + Environment.NewLine +
            "ErrorFile=" + ErrorPath + Environment.NewLine);
        return exitCode;
    }

    private static Assembly ResolveAutomationAssembly(object sender, ResolveEventArgs arguments)
    {
        AssemblyName requested;
        try { requested = new AssemblyName(arguments.Name); }
        catch { return null; }

        if (String.Equals(requested.Name, "System.Management.Automation", StringComparison.OrdinalIgnoreCase) &&
            String.IsNullOrEmpty(requested.CultureName))
        {
            try { return Assembly.LoadFrom(AutomationAssemblyPath); }
            catch { return null; }
        }

        // ResourceManager asks for a culture satellite such as
        // System.Management.Automation.resources.  Never satisfy that request
        // with the neutral SMA assembly: doing so causes the InitialSessionState
        // type initializer to fail.  Let normal CLR resource fallback handle a
        // missing satellite, while accepting only an existing exact satellite.
        if (String.Equals(requested.Name, "System.Management.Automation.resources", StringComparison.OrdinalIgnoreCase) &&
            !String.IsNullOrEmpty(requested.CultureName))
        {
            string baseDirectory = Path.GetDirectoryName(AutomationAssemblyPath);
            string satellite = Path.Combine(baseDirectory, requested.CultureName, requested.Name + ".dll");
            if (File.Exists(satellite))
            {
                try { return Assembly.LoadFrom(satellite); }
                catch { return null; }
            }
        }
        return null;
    }

    [STAThread]
    private static int Main()
    {
        AppDomain.CurrentDomain.AssemblyResolve += ResolveAutomationAssembly;
        return Run();
    }
}
