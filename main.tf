module "mynetwork"{
    source = "./module/networking"
    cidr = "10.10.0.0/16"
}

module "mynetwork2"{
    source = "./module/networking"
    cidr = "10.20.0.0/16"
}
