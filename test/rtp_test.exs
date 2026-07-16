defmodule RtpTest do
  use ExUnit.Case, async: false

  setup_all do
    # Start Mnesia and the RTP application if they aren't started
    Application.ensure_all_started(:rtp)
    on_exit(fn ->
      # Clean up files created during the test
      for i <- 1..4 do
        File.rm("room_room_#{i}.mp4")
      end
    end)
    :ok
  end

  test "simulates 4 rooms and records video using K6" do
    # Run the K6 test script
    IO.puts("Running K6 simulation...")
    {output, exit_code} = System.cmd("k6", ["run", "test/k6_sim.js"])
    IO.puts(output)

    assert exit_code == 0, "K6 test failed"

    # Wait briefly for ports to flush and close files
    Process.sleep(2000)

    # Verify that the GStreamer mixed MP4 files are generated
    for i <- 1..4 do
      filename = "room_room_#{i}.mp4"
      assert File.exists?(filename), "Recording file #{filename} was not created"
      
      stat = File.stat!(filename)
      assert stat.size > 0, "Recording file #{filename} is empty"
      IO.puts("Verified: #{filename} successfully recorded (#{stat.size} bytes)")
    end
  end
end
