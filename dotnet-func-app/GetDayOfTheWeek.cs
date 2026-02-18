using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using System.Net;
using System.Threading.Tasks;

namespace get_dow_api;

public class GetDayOfTheWeek
{
    private readonly ILogger<GetDayOfTheWeek> _logger;

    public GetDayOfTheWeek(ILogger<GetDayOfTheWeek> logger)
    {
        _logger = logger;
    }

    [Function("GetDayOfTheWeek")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", "post")] HttpRequestData req)
    {
        _logger.LogInformation("C# HTTP trigger function processed a request.");

        var response = req.CreateResponse(HttpStatusCode.OK);
        await response.WriteStringAsync("Welcome to Azure Functions!");
        return response;
    }
}
