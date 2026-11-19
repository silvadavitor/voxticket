using NotificationService.Api;
using NotificationService.Hosting;

var app = WebApplication.CreateBuilder(args).AddNotificationService().Build();

app.MapHealthEndpoints();

app.Run();
