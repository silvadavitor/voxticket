using RequestService.Api;
using RequestService.Hosting;

var app = WebApplication.CreateBuilder(args).AddRequestService().Build();

app.MapAudioEndpoints();
app.MapHealthEndpoints();
app.UseOutboxMetrics();

app.Run();
