using Azure.AI.Projects;
using Azure.AI.Projects.OpenAI;
using Microsoft.Agents.AI;
using Microsoft.Extensions.Logging;
using System.Text.Json;
using System.Text.Json.Serialization;

public sealed class RepairPlannerAgent(
    AIProjectClient projectClient,
    CosmosDbService cosmosDb,
    IFaultMappingService faultMapping,
    string modelDeploymentName,
    ILogger<RepairPlannerAgent> logger)
{
    private const string AgentName = "RepairPlannerAgent";
    private const string AgentInstructions = """
        You are a Repair Planner Agent for tire manufacturing equipment.
        Generate a repair plan with tasks, timeline, and resource allocation.
        Return the response as valid JSON matching the WorkOrder schema.
        
        Output JSON with these fields:
        - workOrderNumber, machineId, title, description
        - type: "corrective" | "preventive" | "emergency"
        - priority: "critical" | "high" | "medium" | "low"
        - status, assignedTo (technician id or null), notes
        - estimatedDuration: integer (minutes, e.g. 60 not "60 minutes")
        - partsUsed: [{ partId, partNumber, quantity }]
        - tasks: [{ sequence, title, description, estimatedDurationMinutes (integer), requiredSkills, safetyNotes }]
        
        IMPORTANT: All duration fields must be integers representing minutes (e.g. 90), not strings.
        
        Rules:
        - Assign the most qualified available technician
        - Include only relevant parts; empty array if none needed
        - Tasks must be ordered and actionable
        """;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
    };

    public async Task EnsureAgentVersionAsync(CancellationToken ct = default)
    {
        var definition = new PromptAgentDefinition(model: modelDeploymentName) { Instructions = AgentInstructions };
        await projectClient.Agents.CreateAgentVersionAsync(AgentName, new AgentVersionCreationOptions(definition), ct);
        logger.LogInformation("Ensured agent version for {AgentName}", AgentName);
    }

    public async Task<WorkOrder> PlanAndCreateWorkOrderAsync(DiagnosedFault fault, CancellationToken ct = default)
    {
        // 1. Get required skills and parts from mapping
        var requiredSkills = faultMapping.GetRequiredSkills(fault.FaultType);
        var requiredParts = faultMapping.GetRequiredParts(fault.FaultType);
        logger.LogInformation("Fault {FaultType}: requires skills {Skills}, parts {Parts}",
            fault.FaultType, string.Join(", ", requiredSkills), string.Join(", ", requiredParts));

        // 2. Query technicians and parts from Cosmos DB
        var availableTechnicians = await cosmosDb.GetAvailableTechniciansAsync(requiredSkills, ct);
        var parts = await cosmosDb.GetPartsByNumbersAsync(requiredParts, ct);

        // 3. Build prompt and invoke agent
        var technicianList = string.Join(", ", availableTechnicians.Select(t => $"{t.Id}: {t.Name} ({string.Join(", ", t.Skills)})"));
        var partsList = string.Join(", ", parts.Select(p => $"{p.PartNumber}: {p.Name} (qty: {p.Quantity})"));

        var prompt = $"""
            Diagnosed fault: {fault.FaultType} on machine {fault.MachineId}.
            Description: {fault.Description}

            Available technicians: {technicianList}
            Available parts: {partsList}

            Generate a repair work order in JSON format.
            """;

        var agent = projectClient.GetAIAgent(name: AgentName);
        var response = await agent.RunAsync(prompt, thread: null, options: null, cancellationToken: ct);
        var resultJson = response.Text ?? "{}";
        logger.LogInformation("AI response: {Response}", resultJson);

        // 4. Parse response and apply defaults
        var workOrder = JsonSerializer.Deserialize<WorkOrder>(resultJson, JsonOptions) ?? new WorkOrder();
        workOrder.Id ??= Guid.NewGuid().ToString();
        workOrder.WorkOrderNumber ??= $"WO-{DateTime.UtcNow:yyyyMMdd}-{Guid.NewGuid().ToString().Substring(0, 8)}";
        workOrder.MachineId ??= fault.MachineId;
        workOrder.Type ??= "corrective";
        workOrder.Priority ??= "medium";
        workOrder.Status ??= "open";
        workOrder.AssignedTo ??= availableTechnicians.FirstOrDefault()?.Id;
        workOrder.Notes ??= $"Planned for fault: {fault.FaultType}";
        workOrder.EstimatedDuration = workOrder.EstimatedDuration == 0 ? 60 : workOrder.EstimatedDuration;

        // Ensure partsUsed are valid
        workOrder.PartsUsed = workOrder.PartsUsed
            .Where(pu => parts.Any(p => p.PartNumber == pu.PartNumber))
            .ToList();

        // Ensure tasks have valid durations
        foreach (var task in workOrder.Tasks)
        {
            task.EstimatedDurationMinutes = task.EstimatedDurationMinutes == 0 ? 30 : task.EstimatedDurationMinutes;
        }

        // 5. Save to Cosmos DB
        await cosmosDb.CreateWorkOrderAsync(workOrder, ct);
        logger.LogInformation("Created work order {WorkOrderId} for fault {FaultType}", workOrder.Id, fault.FaultType);

        return workOrder;
    }
}