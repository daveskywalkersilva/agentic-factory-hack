using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Azure.AI.Projects;
using Azure.Identity;
using Microsoft.Extensions.Options;
using System.Text.Json;

var services = new ServiceCollection();
services.AddLogging(builder => builder.AddConsole());

var cosmosEndpoint = Environment.GetEnvironmentVariable("COSMOS_ENDPOINT") ?? throw new InvalidOperationException("COSMOS_ENDPOINT not set");
var cosmosKey = Environment.GetEnvironmentVariable("COSMOS_KEY") ?? throw new InvalidOperationException("COSMOS_KEY not set");
var cosmosDatabase = Environment.GetEnvironmentVariable("COSMOS_DATABASE_NAME") ?? throw new InvalidOperationException("COSMOS_DATABASE_NAME not set");

var aiProjectEndpoint = Environment.GetEnvironmentVariable("AZURE_AI_PROJECT_ENDPOINT") ?? throw new InvalidOperationException("AZURE_AI_PROJECT_ENDPOINT not set");

services.Configure<CosmosDbOptions>(options =>
{
    options.Endpoint = cosmosEndpoint;
    options.Key = cosmosKey;
    options.DatabaseName = cosmosDatabase;
});

services.AddSingleton<AIProjectClient>(_ => new AIProjectClient(new Uri(aiProjectEndpoint), new DefaultAzureCredential()));

services.AddSingleton<IFaultMappingService, FaultMappingService>();
services.AddSingleton<CosmosDbService>();
services.AddSingleton<RepairPlannerAgent>();

var modelDeploymentName = Environment.GetEnvironmentVariable("MODEL_DEPLOYMENT_NAME");

if (string.IsNullOrWhiteSpace(modelDeploymentName))
{
    Console.WriteLine("WARNING: MODEL_DEPLOYMENT_NAME not set. Defaulting to 'gpt-4o'.");
    modelDeploymentName = "gpt-4o";
}

services.AddSingleton(modelDeploymentName);

await using var provider = services.BuildServiceProvider();

var agent = provider.GetRequiredService<RepairPlannerAgent>();
var logger = provider.GetRequiredService<ILogger<RepairPlannerAgent>>();

try
{
    Console.WriteLine("Ensuring agent version...");
    await agent.EnsureAgentVersionAsync();

    Console.WriteLine("Creating sample fault...");
    var sampleFault = new DiagnosedFault
    {
        Id = Guid.NewGuid().ToString(),
        FaultType = "curing_temperature_excessive",
        MachineId = "TIRE-CURING-001",
        Description = "Curing temperature exceeded safe limits by 50°C"
    };

    Console.WriteLine("Planning and creating work order...");
    var workOrder = await agent.PlanAndCreateWorkOrderAsync(sampleFault);

    Console.WriteLine("Work order created successfully:");
    Console.WriteLine(JsonSerializer.Serialize(workOrder, new JsonSerializerOptions { WriteIndented = true }));
}
catch (Exception ex)
{
    logger.LogError(ex, "Error in repair planning workflow");
    Console.WriteLine($"Error: {ex.Message}");
}
