using System.Text.Json;
using Tvoice.Windows.Models;
using Tvoice.Windows.Sip;
using Tvoice.Windows.ViewModels;

var json = new JsonSerializerOptions(JsonSerializerDefaults.Web);

var login = JsonSerializer.Deserialize<LoginResponse>(
    """
    {
      "accessToken": "test-token",
      "expiresIn": 2592000,
      "user": {
        "id": "bb854661-769a-443c-8ce1-18a0f30756da",
        "sipNumber": "73302",
        "displayName": "73302"
      }
    }
    """,
    json);
Assert(login?.User.SipNumber == "73302", "Login response model");

var conversations = JsonSerializer.Deserialize<ConversationsResponse>(
    """
    {
      "conversations": [{
        "id": "85c004d4-cf8d-4a76-af87-11407f466d0b",
        "peer": {
          "id": "a89c3f7c-2018-419d-bbea-f9b6a5fca480",
          "sipNumber": "77770",
          "displayName": "77770"
        },
        "lastMessage": {
          "id": "31",
          "body": "Привет",
          "createdAt": "2026-07-30T04:00:00Z"
        }
      }]
    }
    """,
    json);
Assert(conversations?.Conversations.Single().Peer.SipNumber == "77770", "Conversation response model");

var messages = JsonSerializer.Deserialize<MessagesResponse>(
    """
    {
      "messages": [{
        "id": "31",
        "sender": {
          "id": "bb854661-769a-443c-8ce1-18a0f30756da",
          "sipNumber": "73302",
          "displayName": "73302"
        },
        "body": "Проверка Windows",
        "createdAt": "2026-07-30T04:00:00Z",
        "status": "delivered"
      }]
    }
    """,
    json);
Assert(messages?.Messages.Single().Status == "delivered", "Message delivery model");

var parsedSip = SipMessage.Parse(
    "SIP/2.0 401 Unauthorized\r\nVia: SIP/2.0/UDP 10.0.0.2:5090;rport=5090;received=185.1.2.3\r\nCall-ID: call-1\r\nCSeq: 1 REGISTER\r\nContent-Length: 0\r\n\r\n"u8);
Assert(parsedSip?.StatusCode == 401 && parsedSip.CSeqMethod == "REGISTER", "SIP parser");
Assert(ViaMapping.Parse(parsedSip?.Header("Via")) == new ViaMapping("185.1.2.3", 5090), "SIP rport mapping");

var digest = DigestAuthorization.Create(
    new DigestChallenge(
        "testrealm@host.com",
        "dcd98b7102dd2f0e8b11d0f600bfb0c093",
        "auth",
        "5ccc069c403ebaf9f0171e9517f40e41",
        "MD5"),
    "Mufasa",
    "Circle Of Life",
    "GET",
    "/dir/index.html",
    1,
    "0a4f113b");
Assert(digest.Contains("response=\"6629fae49393a05397450978507c4ef1\""), "SIP digest RFC vector");

var originalSample = (short)12000;
var decodedSample = G711.DecodeAlaw(G711.EncodeAlaw(originalSample));
Assert(Math.Abs(originalSample - decodedSample) < 1000, "G.711 A-law codec");

var remoteAudio = RemoteAudioMedia.FromSdp(
    "v=0\r\nc=IN IP4 10.20.30.40\r\nm=audio 18462 RTP/AVP 8 101\r\na=rtpmap:8 PCMA/8000\r\na=rtpmap:101 telephone-event/8000\r\n",
    System.Net.IPAddress.Loopback);
Assert(remoteAudio?.Endpoint.ToString() == "10.20.30.40:18462", "SDP audio endpoint");
Assert(remoteAudio?.Codec == AudioCodec.Pcma, "SDP G.711 codec negotiation");
Assert(remoteAudio?.TelephoneEventPayload == 101, "SDP telephone-event negotiation");

var videoCredentials = JsonSerializer.Deserialize<VideoCallCredentials>(
    """
    {"callId":"2c908d6f-1c36-43d5-98e4-19d338bdd0a0","room":"tvoice-test","url":"wss://video.example.test","token":"jwt","peer":{"id":"2","sipNumber":"77770","displayName":"77770"},"delivered":true}
    """, json);
Assert(videoCredentials?.Delivered == true && videoCredentials.Peer.SipNumber == "77770", "LiveKit credentials model");

RunCallsTabUiSmoke();

Console.WriteLine("Tvoice Windows smoke tests passed: 12/12");

static void Assert(bool condition, string name)
{
    if (!condition) throw new InvalidOperationException($"Failed: {name}");
}

static void RunCallsTabUiSmoke()
{
    Exception? failure = null;
    var thread = new Thread(() =>
    {
        try
        {
            var app = new Tvoice.Windows.App();
            app.InitializeComponent();
            var window = new Tvoice.Windows.MainWindow();
            var viewModel = (MainViewModel)window.DataContext;
            viewModel.IsAuthenticated = true;
            viewModel.CallHistory.Insert(0, new CallHistoryEntry(
                "77770", false, false, DateTimeOffset.Now, 65, "Завершён"));
            viewModel.SelectedTabIndex = 1;
            window.Measure(new System.Windows.Size(1120, 760));
            window.Arrange(new System.Windows.Rect(0, 0, 1120, 760));
            window.UpdateLayout();
            window.Close();
            app.Shutdown();
        }
        catch (Exception exception) { failure = exception; }
    });
    thread.SetApartmentState(ApartmentState.STA);
    thread.Start();
    if (!thread.Join(TimeSpan.FromSeconds(15)))
        throw new TimeoutException("Failed: Calls tab UI smoke timed out");
    if (failure is not null) throw new InvalidOperationException("Failed: Calls tab UI smoke", failure);
}
