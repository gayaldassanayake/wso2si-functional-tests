package org.wso2.si.test.ldapctx;

import org.osgi.framework.BundleActivator;
import org.osgi.framework.BundleContext;
import org.osgi.framework.ServiceRegistration;

/**
 * Registers the JDK LDAP InitialContextFactory as an OSGi service so that carbon-jndi can resolve
 * java.naming.factory.initial=com.sun.jndi.ldap.LdapCtxFactory.
 */
public class Activator implements BundleActivator {

    private static final String LDAP_CTX_FACTORY = "com.sun.jndi.ldap.LdapCtxFactory";

    private ServiceRegistration<?> registration;

    @Override
    public void start(BundleContext context) throws Exception {
        Object factory = Class.forName(LDAP_CTX_FACTORY).getDeclaredConstructor().newInstance();
        registration = context.registerService(
                new String[]{"javax.naming.spi.InitialContextFactory", LDAP_CTX_FACTORY}, factory, null);
    }

    @Override
    public void stop(BundleContext context) {
        if (registration != null) {
            registration.unregister();
        }
    }
}
