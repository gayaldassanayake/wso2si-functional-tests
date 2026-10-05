package org.wso2.si.test.thrift;

import org.wso2.carbon.databridge.agent.AgentHolder;
import org.wso2.carbon.databridge.agent.DataPublisher;
import org.wso2.carbon.databridge.commons.Event;

/**
 * Publishes events to an SI DataBridge Thrift receiver from outside the server, the way
 * an external publisher such as API Manager does.
 *
 * Usage: ThriftPublisher agentConfig dataUrl authUrl user password streamId transport count
 */
public final class ThriftPublisher {

    private ThriftPublisher() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 8) {
            System.err.println("Usage: ThriftPublisher agentConfig dataUrl authUrl user password streamId "
                    + "transport count");
            System.exit(2);
        }
        AgentHolder.setConfigPath(args[0]);
        DataPublisher publisher = new DataPublisher("Thrift", args[1], args[2], args[3], args[4]);
        int count = Integer.parseInt(args[7]);
        int sent = 0;
        for (int i = 1; i <= count; i++) {
            Event event = new Event(args[5], System.currentTimeMillis(), null, null,
                    new Object[]{args[6], "EXT", 1.5, i});
            if (publisher.tryPublish(event, 10000)) {
                sent++;
            }
        }
        // Lets the async queue drain before the connection closes.
        Thread.sleep(3000);
        publisher.shutdownWithAgent();
        System.out.println("PUBLISHED " + sent + "/" + count);
        System.exit(sent == count ? 0 : 1);
    }
}
