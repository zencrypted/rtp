-record(rtp_token, {
    token :: binary(),        % unique session token
    user :: binary(),         % username
    room :: binary(),         % room name
    device :: binary() | undefined, % WebRTC device peer ID
    expiry :: integer()       % gregorian seconds expiry timestamp
}).
