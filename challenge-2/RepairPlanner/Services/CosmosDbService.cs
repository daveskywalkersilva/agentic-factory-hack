using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System.Text.Json;

public sealed class CosmosDbService
{
    private readonly CosmosClient _cosmosClient;
    private readonly string _databaseName;
    private readonly ILogger<CosmosDbService> _logger;

    public CosmosDbService(IOptions<CosmosDbOptions> options, ILogger<CosmosDbService> logger)
    {
        _cosmosClient = new CosmosClient(options.Value.Endpoint, options.Value.Key);
        _databaseName = options.Value.DatabaseName;
        _logger = logger;
    }

    public async Task<List<Technician>> GetAvailableTechniciansAsync(IReadOnlyList<string> requiredSkills, CancellationToken ct = default)
    {
        try
        {
            var container = _cosmosClient.GetContainer(_databaseName, "Technicians");
            var query = new QueryDefinition("SELECT * FROM c WHERE c.isAvailable = true");
            var iterator = container.GetItemQueryIterator<Technician>(query);
            var technicians = new List<Technician>();

            while (iterator.HasMoreResults)
            {
                var response = await iterator.ReadNextAsync(ct);
                technicians.AddRange(response);
            }

            // Filter in memory for technicians who have all required skills
            var qualifiedTechnicians = technicians
                .Where(t => requiredSkills.All(skill => t.Skills.Contains(skill, StringComparer.OrdinalIgnoreCase)))
                .ToList();

            _logger.LogInformation("Found {Count} qualified technicians for skills: {Skills}", qualifiedTechnicians.Count, string.Join(", ", requiredSkills));
            return qualifiedTechnicians;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error querying available technicians for skills: {Skills}", string.Join(", ", requiredSkills));
            throw;
        }
    }

    public async Task<List<Part>> GetPartsByNumbersAsync(IReadOnlyList<string> partNumbers, CancellationToken ct = default)
    {
        if (partNumbers.Count == 0)
        {
            return new List<Part>();
        }

        try
        {
            var container = _cosmosClient.GetContainer(_databaseName, "PartsInventory");
            var parameters = partNumbers.Select((p, i) => new { Name = $"@p{i}", Value = p }).ToList();
            var inClause = string.Join(", ", parameters.Select(p => p.Name));
            var query = new QueryDefinition($"SELECT * FROM c WHERE c.partNumber IN ({inClause})");

            foreach (var param in parameters)
            {
                query.WithParameter(param.Name, param.Value);
            }

            var iterator = container.GetItemQueryIterator<Part>(query);
            var parts = new List<Part>();

            while (iterator.HasMoreResults)
            {
                var response = await iterator.ReadNextAsync(ct);
                parts.AddRange(response);
            }

            _logger.LogInformation("Fetched {Count} parts for part numbers: {PartNumbers}", parts.Count, string.Join(", ", partNumbers));
            return parts;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error fetching parts for part numbers: {PartNumbers}", string.Join(", ", partNumbers));
            throw;
        }
    }

    public async Task CreateWorkOrderAsync(WorkOrder workOrder, CancellationToken ct = default)
    {
        try
        {
            if (string.IsNullOrEmpty(workOrder.Id))
            {
                workOrder.Id = Guid.NewGuid().ToString();
            }

            var container = _cosmosClient.GetContainer(_databaseName, "WorkOrders");
            await container.CreateItemAsync(workOrder, new PartitionKey(workOrder.Status), cancellationToken: ct);
            _logger.LogInformation("Created work order {WorkOrderId} with status {Status}", workOrder.Id, workOrder.Status);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error creating work order {WorkOrderId}", workOrder.Id);
            throw;
        }
    }
}